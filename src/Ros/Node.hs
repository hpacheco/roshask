{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, ExistentialQuantification #-}
-- |The primary entrypoint to the ROS client library portion of
-- roshask. This module defines the actions used to configure a ROS
-- Node.
module Ros.Node (getThreads,addCleanup,forkNode,nodeTIO,Node, runNode, Subscribe, Advertise,
                 getShutdownAction, runHandler, getParam,
                 getParamOpt, getName, getNamespace,
                 subscribe, advertise, advertiseBuffered,
                 module Ros.Internal.RosTypes, Topic(..),
                 module Ros.Internal.RosTime, liftIO) where
import Control.Applicative ((<$>))
import Control.Concurrent (newEmptyMVar, readMVar, putMVar,killThread)
import Control.Concurrent.BoundedChan
import Control.Concurrent.STM (atomically,newTVarIO,readTVar,modifyTVar)
import Control.Concurrent.Hierarchy
import Control.Concurrent.HierarchyInternal
import Control.Monad (when)
import Control.Monad.State (liftIO, get, gets, put, execStateT,modify)
import Control.Monad.Reader (ask, asks, runReaderT)
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Concurrent (ThreadId)
import Data.Dynamic
import System.Environment (getEnvironment, getArgs)
import Network.XmlRpc.Internals (XmlRpcType)
import qualified Data.Map as Map

import Ros.Internal.Msg.MsgInfo
import Ros.Internal.RosBinary (RosBinary)
import Ros.Internal.RosTypes
import Ros.Internal.RosTime
import Ros.Internal.Util.AppConfig (Config, parseAppConfig, forkConfig, forkConfigUnsafe,configured)
import Ros.Internal.Util.ArgRemapping
import Ros.Node.Type
import qualified Ros.Graph.ParameterServer as P
import Ros.Node.RosTcp (subStream, runServer)
import qualified Ros.Node.RunNode as RN
import Ros.Topic
import Ros.Topic.Stats (recvMessageStat, sendMessageStat)
import Ros.Topic.Util (configTIO,TIO,share,shareUnsafe)

import qualified Control.Monad.Except as E
import qualified Control.Exception as E

getThreads :: Node ThreadMap
getThreads = gets threads

extendThreadMap :: ThreadMap -> ThreadMap -> IO ()
extendThreadMap (ThreadMap v1) (ThreadMap v2) = atomically $ do
    m2 <- readTVar v2
    modifyTVar v1 $ Map.union m2 

forkNode :: Node () -> Node ThreadMap
forkNode n = do
    s <- get
    let ts = threads s
    children <- liftIO $ newThreadMap
    put $ s { threads = children }
    n
    liftIO $ extendThreadMap ts children
    modify $ \s -> s { threads = ts }
    return children

nodeTIO :: TIO a -> Node a
nodeTIO m = do
    ts <- gets threads
    liftIO $ runReaderT m ts

-- |ROS topic subscriber
class Subscribe s where
    -- |Subscrive to given topic name
    subscribe :: (RosBinary a, MsgInfo a, Typeable a)
              => TopicName -> Node (s a)

type Cleanup = IO ()

-- |ROS topic publisher
class Advertise a where
    -- |Advertise topic messages with a per-client
    -- transmit buffer of the specified size.
    advertiseBuffered :: (RosBinary b, MsgInfo b, Typeable b)
                      => Int -> TopicName -> a b -> Node ()
    -- |Advertise a 'Topic' publishing a stream of values produced in
    -- the 'IO' monad. Fixed buffer size version of @advertiseBuffered@.
    advertise :: (RosBinary b, MsgInfo b, Typeable b)
              => TopicName -> a b -> Node ()
    advertise = advertiseBuffered 1

instance Subscribe (Topic TIO) where
    subscribe = subscribe_

instance Advertise (Topic TIO) where
    advertiseBuffered = advertiseBuffered_

-- |Maximum number of items to buffer for a subscriber.
recvBufferSize :: Int
recvBufferSize = 10

-- |Spark a thread that funnels a Stream from a URI into the given
-- Chan.
addSource :: (RosBinary a, MsgInfo a) =>
             String -> (URI -> Int -> IO ()) -> BoundedChan a -> URI ->
             Config ThreadId
addSource tname updateStats c uri =
    forkConfigUnsafe $ do
        t <- subStream uri tname (updateStats uri)
        configTIO $ forever $ join $ fmap (liftIO . writeChan c) t

-- Create a new Subscription value that will act as a named input
-- channel with zero or more connected publishers.
mkSub :: forall a. (RosBinary a, MsgInfo a,Typeable a) =>
         String -> Config (Topic TIO a,Subscription)
mkSub tname = do c <- liftIO $ newBoundedChan recvBufferSize
                 let stream = Topic $ do x <- liftIO (readChan c)
                                         return (x, stream)
                 known <- liftIO $ newTVarIO S.empty
                 stats <- liftIO $ newTVarIO M.empty
                 (stream',tid) <- configTIO $ shareUnsafe stream
                 cleanSub <- liftIO $ newTVarIO $ killThread tid
                 (r,ts) <- ask
                 let topicType = msgTypeName (undefined::a)
                     updateStats = recvMessageStat stats
                     addSource' = flip runReaderT (r,ts) . addSource tname updateStats c
                     sub = Subscription known addSource' topicType (DynBoundedChan c) (DynTopic stream') stats cleanSub
                 return (stream',sub)

-- hpacheco: support multiple publishers within the same node
mkPub :: forall a. (RosBinary a, MsgInfo a, Typeable a) =>
         Topic TIO a -> Maybe Publication -> Int -> Config (Publication)
mkPub (t0::Topic TIO a) mbpub n = do
    pub <- case mbpub of
        Nothing -> do
            (tchan::BoundedChan a) <- liftIO $ newBoundedChan n
            let (t'::Topic TIO a) = Topic $ do { x <- liftIO (readChan tchan); return (x,t') }
            (t'',tid) <- configTIO $ shareUnsafe t'
            mkPubAux (msgTypeName (undefined::a)) t'' tchan (runServer t'') n tid
        Just pub -> return pub
    tchan <- case fromDynBoundedChan (pubChan pub) of
        Nothing -> error $ "Already published to topic with a different type."
        Just tchan -> return tchan
    let feed t = do { (x,t') <- runTopic t; liftIO (writeChan tchan x); feed t' }
    -- return a ThreadId to allow killing the topic publisher
    _ <- forkConfig $ do
            ts <- asks Prelude.snd
            liftIO $ runReaderT (feed t0) ts
    return (pub)

mkPubAux :: Typeable a =>
            String -> Topic TIO a -> BoundedChan a ->
            ((URI -> Int -> IO ()) -> Int -> Config (Config (), Int)) ->
            Int -> ThreadId -> Config Publication
mkPubAux trep t tchan runServer' bufferSize tid = do
    stats <- liftIO $ newTVarIO M.empty
    (cleanup, port) <- runServer' (sendMessageStat stats) bufferSize
    known <- liftIO $ newTVarIO S.empty
    cleanup' <- configured cleanup
    cleanPub <- liftIO $ newTVarIO $ cleanup' >> killThread tid
    return $ Publication known trep port (DynBoundedChan tchan) (DynTopic t) stats cleanPub

-- |Subscribe to the given Topic. Returns a 'Ros.Topic.Util.share'd 'Topic'.
subscribe_ :: (RosBinary a, MsgInfo a, Typeable a)
           => TopicName -> Node (Topic TIO a)
subscribe_ name =
    do n <- get
       name' <- canonicalizeName =<< remapName name
       r <- nodeAppConfig <$> ask
       ts <- gets threads
       let subs = subscriptions n
       case (M.lookup name' subs) of
           Just sub -> case fromDynTopic (subTopic sub) of
               Nothing -> error $ "Already subscribed to topic " ++ name' ++ " with a different type."
               Just stream -> return stream
           Nothing -> do
             let pubs = publications n
             --if M.member name' pubs -- TODO: shouldn't happen, ignoring other possible publishers
             --  then return . fromDynErr . pubTopic $ pubs M.! name'
             (stream,sub) <- liftIO $ runReaderT (mkSub name') (r,ts)
             put n { subscriptions = M.insert name' sub subs }
             RN.registerSubscriptionNode name' sub
             return stream
--  where fromDynErr = maybe (error msg) id . fromDynTopic
--        msg = "Subscription to "++name++" at a different type than "++
--              "what that Topic was already advertised at by this Node."

-- |Spin up a thread within a Node. This is typically used for message
-- handlers. Note that the supplied 'Topic' is traversed solely for
-- any side effects of its steps; the produced values are ignored.
runHandler :: (a -> TIO b) -> Topic TIO a -> Node ThreadId
runHandler go topic = do
    ts <- gets threads
    liftIO $ newChild ts $ \ts' -> runReaderT (forever $ join $ fmap go topic) ts'

advertiseAux :: (Maybe Publication -> Int -> Config (Publication)) -> Int -> TopicName -> Node ()
advertiseAux mkPub' bufferSize name =
    do n <- get
       name' <- remapName =<< canonicalizeName name
       r <- nodeAppConfig <$> ask
       ts <- gets threads
       let pubs = publications n
       let mbpub = M.lookup name' pubs 
       (pub') <- liftIO $ runReaderT (mkPub' mbpub bufferSize) (r,ts)
       put n { publications = M.insert name' pub' pubs }
       RN.registerPublicationNode name' pub'

-- |Advertise a 'Topic' publishing a stream of 'IO' values with a
-- per-client transmit buffer of the specified size.
advertiseBuffered_ :: (RosBinary a, MsgInfo a, Typeable a) =>
                     Int -> TopicName -> Topic TIO a -> Node ()
advertiseBuffered_ bufferSize name s = advertiseAux (mkPub s) bufferSize name

-- -- |Existentially quantified message type that roshask can
-- -- serialize. This type provides a way to work with collections of
-- -- differently typed 'Topic's.
-- data SomeMsg = forall a. (RosBinary a, MsgInfo a, Typeable a) => SomeMsg a

-- -- |Advertise projections of a 'Topic' as discrete 'Topic's.
-- advertiseSplit :: [(TopicName, a -> SomeMsg)] -> Topic IO a -> Node ()
-- advertiseSplit = undefined

-- |Get an action that will shutdown this Node.
getShutdownAction :: Node (IO ())
getShutdownAction = get >>= liftIO . readMVar . signalShutdown

-- |Apply any matching renames to a given name.
remapName :: String -> Node String
remapName name = asks (maybe name id . lookup name . nodeRemaps)

-- |Convert relative names to absolute names. Leaves absolute names
-- unchanged.
canonicalizeName :: String -> Node String
canonicalizeName n@('/':_) = return n
canonicalizeName ('~':n) = do state <- get
                              let node = nodeName state
                              return $ node ++ "/" ++ n
canonicalizeName n = do (++n) . namespace <$> get

-- |Get a parameter value from the Parameter Server.
getServerParam :: XmlRpcType a => String -> Node (Maybe a)
getServerParam var = do state <- get
                        let masterUri = master state
                            myName = nodeName state
                        -- Call hasParam first because getParam only returns
                        -- a partial result (just the return code) in failure.
                        hasParam <- liftIO $ P.hasParam masterUri myName var
                        case hasParam of
                          Right True -> liftIO $ P.getParam masterUri myName var
                          _ -> return Nothing

-- |Get the value associated with the given parameter name. If the
-- parameter is not set, then 'Nothing' is returned; if the parameter
-- is set to @x@, then @Just x@ is returned.
getParamOpt :: (XmlRpcType a, FromParam a) => String -> Node (Maybe a)
getParamOpt var = do var' <- remapName =<< canonicalizeName var
                     params <- nodeParams <$> ask
                     case lookup var' params of
                       Just val -> return . Just $ fromParam val
                       Nothing -> getServerParam var'

-- |Get the value associated with the given parameter name. If the
-- parameter is not set, return the second argument as the default
-- value.
getParam :: (XmlRpcType a, FromParam a) => String -> a -> Node a
getParam var def = maybe def id <$> getParamOpt var

-- |Get the current node's name.
getName :: Node String
getName = nodeName <$> get

-- |Get the current namespace.
getNamespace :: Node String
getNamespace = namespace <$> get

addCleanup :: IO () -> Node ()
addCleanup m = do
    c <- gets nodeCleanup
    liftIO $ atomically $ modifyTVar c (>> m)

-- |Run a ROS Node.
runNode :: NodeName -> Node a -> IO ()
runNode name (Node nConf) =
    do myURI <- newEmptyMVar
       sigStop <- newEmptyMVar
       env <- liftIO getEnvironment
       newts <- newThreadMap
       clean <- newTVarIO $ return ()
       (conf, args) <- parseAppConfig <$> liftIO getArgs
       let getConfig' var def = maybe def id $ lookup var env
           getConfig = flip lookup env
           masterConf = getConfig' "ROS_MASTER_URI" "http://localhost:11311"
           namespaceConf = let ns = getConfig' "ROS_NAMESPACE" "/"
                           in if last ns == '/' then ns else ns ++ "/"
           (nameMap, params) = parseRemappings args
           name' = case lookup "__name" params of
                     Just x -> fromParam x
                     Nothing -> case name of
                                  '/':_ -> name
                                  _ -> namespaceConf ++ name
           -- Name remappings apply to exact strings and resolved names.
           resolve p@(('/':_),_) = [p]
           resolve (('_':n),v) = [(name'++"/"++n, v)]
           resolve (('~':n),v) = [(name'++"/"++ n, v)] --, ('_':n,v)]
           resolve (n,v) = [(namespaceConf ++ n,v), (n,v)]
           nameMap' = concatMap resolve nameMap
           params' = concatMap resolve params
       when (not $ null nameMap')
            (putStrLn $ "Remapping name(s) "++show nameMap')
       when (not $ null params')
            (putStrLn $ "Setting parameter(s) "++show params')
       case getConfig "ROS_IP" of
         Nothing -> case getConfig "ROS_HOSTNAME" of
                      Nothing -> return ()
                      Just n -> putMVar myURI $! "http://"++n
         Just ip -> putMVar myURI $! "http://"++ip
       let configuredNode = runReaderT nConf (NodeConfig params' nameMap' conf)
           initialState = NodeState name' namespaceConf masterConf myURI sigStop M.empty M.empty newts clean
           statefulNode = execStateT configuredNode initialState
       statefulNode >>= flip runReaderT (conf,newts) . RN.runNode name'
