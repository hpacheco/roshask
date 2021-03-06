{-# LANGUAGE CPP, FlexibleContexts, OverloadedStrings #-}
-- |Build all messages defined in a ROS package.
module PkgBuilder where
import Analysis
#if __GLASGOW_HASKELL__ < 800
import Control.Applicative
#endif
import Control.Concurrent (forkIO)
import Control.Concurrent (newEmptyMVar)
import Control.Concurrent (putMVar)
import Control.Concurrent (takeMVar)
import Control.DeepSeq (rnf)
import qualified Control.Exception as C
import Control.Monad (when, zipWithM_)
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (isSpace)
import qualified Data.Foldable as F
import Data.List (intercalate, isSuffixOf, isPrefixOf, nub)
import Data.Version (versionBranch)
import Gen (generateMsgType, generateSrvTypes)
import Parse (parseMsg, parseSrv)
import Types (requestResponseNames, shortName)
import Paths_roshask (version, getBinDir)

import Ros.Internal.DepFinder (findMessages, findDepsWithMessages, hasMsgsOrSrvs, findServices)
import Ros.Internal.PathUtil (codeGenDir, cap, pathToPkgName)
import System.Directory (createDirectoryIfMissing, getDirectoryContents,
                         doesDirectoryExist, removeFile)
import System.Exit (ExitCode(..))
import System.FilePath
import System.IO (hGetContents, hClose)
import System.Process (createProcess, proc, CreateProcess(..), waitForProcess, StdStream(CreatePipe))

-- | Determine if we are working in a sandbox by checking of roshask
-- was installed in one. If so, return the immediate parent of the
-- sandbox directory.
sandboxDir :: IO (Maybe FilePath)
sandboxDir = do d <- splitDirectories <$> getBinDir
                return $ case reverse d of
                           ("bin" : ".cabal-sandbox" : ds) ->
                             Just . joinPath $ reverse ds
                           _ -> Nothing

-- | Information on how to invoke @ghc-pkg@ (or @cabal sandbox
-- hc-pkg@) and the @cabal@ executable.
data ToolPaths = ToolPaths { ghcPkg       :: [String] -> CreateProcess
                           , cabalInstall :: [String] -> CreateProcess
                           , forceFlag    :: [String] }

-- | If we are not in a sandbox, then we can use 'ghc-pkg' to get a
-- list of installed packages, and 'cabal install' to install a
-- package. If we are in a sandbox, we must invoke the tools from the
-- directory containing the sandbox directory, and use @cabal sandbox
-- hc-pkg@ instead of @ghc-pkg@.
toolPaths :: IO ToolPaths
toolPaths =
  sandboxDir >>= \md -> return $ case md of
    Nothing -> ToolPaths (\args -> (proc "ghc-pkg" args)
                                   {std_in=CreatePipe, std_out=CreatePipe})
                         (\args -> proc "cabal" args)
                         ["--force"]
    Just _ -> ToolPaths (\args -> (proc "cabal" ("sandbox":"hc-pkg":args))
                                  {cwd=md, std_out=CreatePipe})
                        (\args -> (proc "cabal" args) {cwd=md})
                        ["--", "--force"]

-- The current version of roshask. We tag generated message packages
-- with the same version.
roshaskVersion :: B.ByteString
roshaskVersion = B.pack . intercalate "." $ map show (versionBranch version)

-- The current version of roshask with the patch level changed to an
-- asterisk. The intension is to allow a compiled roshask package to
-- work with newer patch levels of roshask itself.
roshaskMajorMinor :: B.ByteString
roshaskMajorMinor = B.pack . intercalate "." $
                    map show (take 2 (versionBranch version)) ++ ["*"]

pathToRosPkg :: FilePath -> FilePath
pathToRosPkg = last . splitDirectories

-- | Somewhat more flexibile than 'System.Process.readProcess'. Not as
-- robust to exceptions.
myReadProcess :: CreateProcess -> IO String
myReadProcess cp =
  do (i, Just o, _, ph) <- createProcess cp
     F.mapM_ hClose i
     output <- hGetContents o
     done <- newEmptyMVar
     _ <- forkIO $ C.evaluate (rnf output) >> putMVar done ()
     takeMVar done
     hClose o
     ex <- waitForProcess ph
     case ex of
       ExitSuccess -> return output
       ExitFailure e -> error $ "Error reading process: "++show e

-- Determine if a roshask package is already registered with ghc-pkg
-- for the given ROS package.
packageRegistered :: ToolPaths -> FilePath -> IO Bool
packageRegistered tools pkg =
  any (isPrefixOf cabalPkg . dropWhile isSpace) . lines <$> getList
  where cabalPkg = (rosPkg2CabalPkg $ pathToRosPkg pkg) ++
                   "-" ++ B.unpack roshaskVersion
        getList = myReadProcess $ ghcPkg tools ["list", cabalPkg]

-- | A generated package of message definitions can be written in the
-- current directory or in @~/.cabal/share/roshask@ (only appropriate
-- if installing into a user's package database.
data DestDir = DestHere | DestCabal

-- | Build all messages defined by a ROS package unless the corresponding
-- Haskell package is already registered with ghc-pkg.
buildPkgMsgs :: DestDir -> FilePath -> MsgInfo ()
buildPkgMsgs DestHere fname =
  buildNewPkgMsgs Nothing (pkg</>"Ros"</>pkg) fname
  where pkg = pathToPkgName fname
buildPkgMsgs DestCabal fname =
  do tools <- liftIO toolPaths
     r <- liftIO $ packageRegistered tools fname
     if r
       then liftIO . putStrLn $
            "Using existing " ++ pathToRosPkg fname
       else do destDir <- liftIO $ codeGenDir fname
               buildNewPkgMsgs (Just tools) destDir fname

parseErrorMsg :: Show a => a -> String -> Either String c -> c
parseErrorMsg = parseErrorHelper "message"

parseErrorSrv :: Show a => a -> String -> Either String c -> c
parseErrorSrv = parseErrorHelper "service"

parseErrorHelper :: Show a => String -> a -> String -> Either String c -> c
parseErrorHelper srvOrMsg pkgHier fileName =
  either
  (\s -> error $ "In package: " ++ show pkgHier ++ "Could not parse " ++ srvOrMsg ++ " in file " ++ fileName ++" . Got error :" ++ s)
  id

dirAndNameToFile :: FilePath -> String -> FilePath
dirAndNameToFile destDir = (destDir </>) . (++ ".hs")

-- | Given a FilePath to a service file, will parse the service, generate the Haskell
-- request and response types, and write these types to a directory. This requires
-- knowing the Haskell names for the other messages in the current package
parseGenWriteService :: ByteString -> String -> [ByteString] -> FilePath -> MsgInfo ()
parseGenWriteService pkgHier destDir haskellPkgMsgNames srvFile = do
  parsedSrv <- liftIO $ parseErrorSrv pkgHier srvFile <$> parseSrv srvFile
  (request, response) <- generateSrvTypes pkgHier haskellPkgMsgNames parsedSrv
  let fname = map (dirAndNameToFile destDir) $ requestResponseNames parsedSrv
  liftIO $ zipWithM_ B.writeFile fname [request, response]

-- | Given a FilePath to a message file, will parse the message and generate and write
-- the Haskell type to a directory.
parseGenWriteMsg :: ByteString -> String -> [ByteString] -> FilePath -> MsgInfo ()
parseGenWriteMsg pkgHier destDir haskellPkgMsgNames msgFile = do
  parsedMsg <- liftIO $ parseErrorMsg pkgHier msgFile <$> parseMsg msgFile
  generatedMsg <- generateMsgType pkgHier haskellPkgMsgNames parsedMsg
  let fname = dirAndNameToFile destDir $ shortName parsedMsg
  liftIO $ B.writeFile fname generatedMsg

-- | Generate Haskell implementations of all message definitions in
-- the given package.
buildNewPkgMsgs :: Maybe ToolPaths -> FilePath -> FilePath -> MsgInfo ()
buildNewPkgMsgs tools' destDir fname =
  do liftIO . putStrLn $ "Generating package " ++ fname
     liftIO $ createDirectoryIfMissing True destDir
     pkgMsgs <- liftIO $ findMessages fname
     pkgSrvs <- liftIO $ findServices fname
     let haskellMsgNames = map (B.pack . cap . dropExtension . takeFileName) pkgMsgs
     mapM_ (parseGenWriteMsg pkgHier destDir haskellMsgNames) pkgMsgs
     mapM_ (parseGenWriteService pkgHier destDir haskellMsgNames) pkgSrvs
     liftIO $ do f <- hasMsgsOrSrvs fname
                 when f (removeOldCabal destDir >> compileMsgs)
    where pkgName = pathToRosPkg fname
          pkgHier = B.pack $ "Ros." ++ cap pkgName ++ "."
          compileMsgs =
            do cpath <- genMsgCabal destDir fname pkgName
               case tools' of
                 Just tools -> do (_,_,_,procH) <- createProcess $
                                    cabalInstall tools ["install", cpath]
                                  code <- waitForProcess procH
                                  when (code /= ExitSuccess)
                                       (error $ "Building messages for "++
                                                pkgName++" failed")
                 Nothing -> return ()

-- |Convert a ROS package name to the corresponding Cabal package name
-- defining the ROS package's msg types.
rosPkg2CabalPkg :: String -> String
rosPkg2CabalPkg = ("ROS-"++) . addSuffix . map sanitize
  where sanitize '_' = '-'
        sanitize c   = c
        addSuffix n
          | "msgs" `isSuffixOf` n = n
          | otherwise = n ++ "-msgs"

removeOldCabal :: FilePath -> IO ()
removeOldCabal msgPath =
  do f <- doesDirectoryExist msgPath
     when f (getDirectoryContents msgPath >>=
             mapM_ (removeFile . (msgPath </>)) .
                   filter ((== ".cabal") . takeExtension))

-- Extract a Msg module name from a Path
path2MsgModule :: FilePath -> String
path2MsgModule = intercalate "." . map cap . reverse . take 3 .
                 reverse . splitDirectories . dropExtension

getHaskellFiles :: FilePath -> IO [FilePath]
getHaskellFiles destDir =
  map (destDir </>) . filter ((== ".hs") . takeExtension) <$>
  getDirectoryContents destDir

-- Generate a .cabal file to build this ROS package's messages.
genMsgCabal :: FilePath -> FilePath -> String -> IO FilePath
genMsgCabal destDir pkgPath pkgName =
  do deps' <- map (B.pack . rosPkg2CabalPkg) <$>
              findDepsWithMessages pkgPath
     let cabalFilePath = (</>cabalPkg++".cabal") .
                         joinPath . init . init . splitPath $
                         destDir
         deps
           | pkgName == "std_msgs" = deps'
           | otherwise = nub ("ROS-std-msgs":deps')
     msgFiles <- getHaskellFiles destDir
     let msgModules = map (B.pack . path2MsgModule) msgFiles
         target = B.intercalate "\n" $
                  [ "Library"
                  , B.append "  Exposed-Modules: "
                    (if not (null msgModules)
                    then B.concat [ head msgModules
                                  , "\n"
                                  , B.intercalate "\n"
                                    (map indent (tail msgModules)) ]
                    else "")
                  , ""
                  , "  Build-Depends:   base >= 4.2 && < 6,"
                  , "                   vector > 0.7,"
                  , "                   time >= 1.1,"
                  , "                   data-default-generics >= 0.3,"
                  , "                   lens-family-core >= 1.2,"
                  , "                   lens-family-th >= 0.4.1,"
                  , B.concat [ "                   roshask == "
                             , roshaskMajorMinor
                             , if null deps then ""  else "," ]
                  , B.intercalate ",\n" $
                    map (B.append "                   ") deps
                  , "  GHC-Options:     -O2" ]
         pkgDesc = B.concat [preamble, "\n", target]
         --cabalFilePath = pkgPath</>"msg"</>"haskell"</>cabalPkg++".cabal"
     B.writeFile cabalFilePath pkgDesc
     return cabalFilePath
  where cabalPkg = rosPkg2CabalPkg pkgName
        preamble = format [ ("Name", B.pack cabalPkg)
                          , ("Version", roshaskVersion)
                          , ("Synopsis", B.append "ROS Messages from "
                                                  (B.pack pkgName))
                          , ("Cabal-version", ">=1.6")
                          , ("Category", "Robotics")
                          , ("Build-type", "Simple") ]
        indent = let spaces = B.replicate 19 ' ' in B.append spaces

format :: [(ByteString, ByteString)] -> ByteString
format fields = B.concat $ map indent fields
  where indent (k,v) = let spaces = flip B.replicate ' ' $
                                    21 - B.length k - 1
                       in B.concat [k,":",spaces,v,"\n"]
