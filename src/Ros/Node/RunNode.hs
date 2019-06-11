{-# LANGUAGE ScopedTypeVariables #-}

module Ros.Node.RunNode (runNode) where
import Control.Concurrent (readMVar,forkIO, killThread)
import qualified Control.Concurrent.SSem as Sem
import qualified Control.Exception as E
import Control.Concurrent.BoundedChan
import Control.Monad.IO.Class
import System.Posix.Signals (installHandler, Handler(..), sigINT)
import Ros.Internal.RosTypes
import Ros.Internal.Util.AppConfig (Config, debug)
--import Ros.Graph.Master
--import Ros.Graph.Slave
import Ros.Internal.Util.AppConfig
import Ros.Node.Type
import Ros.Topic (Topic,runTopic)
import qualified Data.Map as Map
import Data.Typeable (gcast)
import Data.Maybe
import Control.Monad

import GHC.Conc


-- Redirect local publishers to local subscribers
registerLocalSubscription :: (String,(Publication,Subscription)) -> Config (Maybe ThreadId)
registerLocalSubscription (topicname,(pub,sub)) = do
    redirectChan (pubTopic pub) (subChan sub)
  where
    redirectChan :: DynTopic -> DynBoundedChan -> Config (Maybe ThreadId)
    redirectChan (DynTopic from) (DynBoundedChan (to::BoundedChan b)) = 
        case gcast from of
            Nothing -> return Nothing
            Just (from'::Topic IO b) -> do
                let go t = do { (x,t') <- runTopic t; writeChan to x; go t' }
                liftM Just $ forkConfig $ liftIO $ go from'

registerNode :: String -> NodeState -> Config [ThreadId]
registerNode name n = 
    do --uri <- liftIO $ readMVar (getNodeURI n)
       --let master = getMaster n
       debug $ "Starting node "++name -- ++" at " ++ uri
       let pubsubs = Map.intersectionWithKey (\k p s -> (p,s)) (publications n) (subscriptions n)
       liftM catMaybes $ mapM (registerLocalSubscription) (Map.toList pubsubs)

-- |Run a ROS Node with the given name. Returns when the Node has
-- shutdown either by receiving an interrupt signal (e.g. Ctrl-C) or
-- because the master told it to stop.
runNode :: String -> NodeState -> Config ()
runNode name s = do
    threads <- registerNode name s
    debug "Spinning"
    allDone <- liftIO $ Sem.new 0
    let ignoreEx :: E.SomeException -> IO ()
        ignoreEx _ = return ()
        shutdown = do putStrLn "Shutting down"
                      mapM_ killThread threads `E.catch` ignoreEx
                      Sem.signal allDone
    liftIO $ setShutdownAction s shutdown
    _ <- liftIO $ 
         installHandler sigINT (CatchOnce shutdown) Nothing
    liftIO $ Sem.wait allDone
