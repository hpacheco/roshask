{-# LANGUAGE CPP, FlexibleInstances, ScopedTypeVariables, ExistentialQuantification #-}
-- |The primary entrypoint to the ROS client library portion of
-- roshask. This module defines the actions used to configure a ROS
-- Node.
module Ros.Node  (getThreads,addCleanup,forkNode,forkNodeIO,nodeTIO,Node, runNode, Subscribe, Advertise,
                 getShutdownAction, runHandler,runHandler_,
--                 getParam, getParamOpt,
                 getName, getNamespace,
                 subscribe, advertise, advertiseBuffered,
                 registerService, callService, getParameter'', getParameter', getParameter, setParameter,
                 module Ros.Internal.RosTypes, Topic(..),
                 module Ros.Internal.RosTime, liftIO) where
import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay,newEmptyMVar, readMVar, putMVar,killThread)
import Control.Concurrent.BoundedChan as BC
import Control.Concurrent.STM (atomically,newTVarIO,readTVar,modifyTVar)
import Control.Concurrent.Hierarchy
import Control.Concurrent.HierarchyInternal
import Control.Concurrent.MVar
import Control.Monad.Trans
import Control.Monad (when,forever)
import Control.Monad.State (liftIO, get, gets, put, execStateT,evalStateT,modify)
import Control.Monad.Reader (ask, asks, runReaderT)
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Concurrent (ThreadId)
import Data.Dynamic
import System.Environment (getEnvironment, getArgs)
import qualified Data.Map as Map
import Data.Proxy
import Control.Monad

import Ros.Internal.Msg.MsgInfo
import Ros.Internal.RosBinary (RosBinary)
import Ros.Internal.RosTypes
import Ros.Internal.RosTime
import Ros.Internal.Util.AppConfig (Config, parseAppConfig, forkConfig, forkConfigUnsafe,configured)
import Ros.Internal.Util.ArgRemapping
import Ros.Node.Type
import qualified Ros.Node.RunNode as RN
import Ros.Topic
import Ros.Topic.Stats (recvMessageStat, sendMessageStat)
import Ros.Topic.Util (configTIO,TIO,share,shareUnsafe,forkTIO)

import qualified Control.Monad.Except as E
import qualified Control.Exception as E

#if defined(ghcjs_HOST_OS)
#else
import qualified Ros.Graph.ParameterServer as P
import qualified Ros.Graph.Slave as Slave
import Ros.Node.RosTcp (subStream, runServer)
import Network.XmlRpc.Internals (XmlRpcType)
#endif    

#if defined(ghcjs_HOST_OS)
runServer _ _ _ = return (return (),0)
#else
#endif

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
    liftIO $ extendThreadMap ts children
    put $ s { threads = children }
    n
    modify $ \s -> s { threads = ts }
    return children
    
forkNodeIO :: Node () -> Node ThreadId
forkNodeIO (Node n) = do
    r <- ask
    s <- get
    let n' = lift $ evalStateT (runReaderT n r) s
    tid <- nodeTIO $ forkTIO n'
    addCleanup $ killThread tid
    return tid

nodeTIO :: TIO a -> Node a
nodeTIO m = do
    ts <- gets threads
    liftIO $ runReaderT m ts

-- |ROS topic subscriber
class Subscribe s where
    -- |Subscrive to given topic name
    subscribe :: (RosBinary a, MsgInfo a, Typeable a)
              => TopicName -> Node (s a)

instance Subscribe (Topic TIO) where
    subscribe = subscribe_

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

instance Advertise (Topic TIO) where
    advertiseBuffered = advertiseBuffered_

-- |Maximum number of items to buffer for a subscriber.
recvBufferSize :: Int
recvBufferSize = 10

-- |Spark a thread that funnels a Stream from a URI into the given
-- Chan.
addSource :: (RosBinary a, MsgInfo a) =>
             String -> (URI -> Int -> IO ()) -> BoundedChan a -> URI ->
             Config (ThreadId)
#if defined(ghcjs_HOST_OS)
addSource tname updateStats c uri = return (error "nothread")
#else
addSource tname updateStats c uri = 
    forkConfigUnsafe $ do
        t <- subStream uri tname (updateStats uri)
        configTIO $ Ros.Topic.forever $ Ros.Topic.join $ fmap (liftIO . writeChan c) t
#endif

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
         Topic TIO a -> Maybe Publication -> Int -> Config (Maybe Publication)
mkPub (t0::Topic TIO a) mbpub n = do
    (isNew,pub) <- case mbpub of
        Nothing -> do
            --liftIO $ putStrLn $ "register new pub"
            (tchan::BoundedChan a) <- liftIO $ newBoundedChan n
            let (t'::Topic TIO a) = Topic $ do { x <- liftIO (readChan tchan); return (x,t') }
            (t'',tid) <- configTIO $ shareUnsafe t'
            pub <- mkPubAux (msgTypeName (undefined::a)) t'' tchan (runServer t'') n tid
            return (True,pub)
        Just pub -> do
            --liftIO $ putStrLn $ "use registered pub"
            return (False,pub)
    tchan <- case fromDynBoundedChan (pubChan pub) of
        Nothing -> error $ "Already published to topic with a different type."
        Just tchan -> return tchan
    let feed ts t = do
            (x,t') <- runTopic t
            liftIO (writeChan tchan x)
            let msgt = msgTypeName (undefined::a)
            --when (msgt=="geometry_msgs/Twist") $ liftIO $ putStrLn $ "published to " ++ msgt 
            feed ts t'
    -- return a ThreadId to allow killing the topic publisher
    _ <- forkConfig $ do
            ts <- asks Prelude.snd
            liftIO $ runReaderT (feed ts t0) ts
    return $ if isNew then Just pub else Nothing

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
       subs <- liftIO $ atomically $ readTVar $ subscriptions n
       case (M.lookup name' subs) of
           Just sub -> case fromDynTopic (subTopic sub) of
               Nothing -> error $ "Already subscribed to topic " ++ name' ++ " with a different type."
               Just stream -> return stream
           Nothing -> do
             pubs <- liftIO $ atomically $ readTVar $ publications n
             --if M.member name' pubs -- TODO: shouldn't happen, ignoring other possible publishers
             --  then return . fromDynErr . pubTopic $ pubs M.! name'
             (stream,sub) <- liftIO $ runReaderT (mkSub name') (r,ts)
             liftIO $ atomically $ modifyTVar (subscriptions n) $ M.insert name' sub
             --put n { subscriptions = M.insert name' sub subs }
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
    liftIO $ newChild ts $ \ts' -> runReaderT (Ros.Topic.forever $ Ros.Topic.join $ fmap go topic) ts'

runHandler_ :: (a -> TIO b) -> Topic TIO a -> Node ()
runHandler_ go topic = runHandler go topic >> return ()

advertiseAux :: (Maybe Publication -> Int -> Config (Maybe Publication)) -> Int -> TopicName -> Node ()
advertiseAux mkPub' bufferSize name =
    do n <- get
       name' <- remapName =<< canonicalizeName name
       r <- nodeAppConfig <$> ask
       ts <- gets threads
       pubs <- liftIO $ atomically $ readTVar $ publications n
       let mbpub = M.lookup name' pubs 
       mb <- liftIO $ runReaderT (mkPub' mbpub bufferSize) (r,ts)
       case mb of
           Nothing -> return ()
           Just pub' -> do
               liftIO $ atomically $ modifyTVar (publications n) $ M.insert name' pub'
               --put n { publications = M.insert name' pub' pubs }
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


#if defined(ghcjs_HOST_OS)
#else
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
#endif

-- |Get the current node's name.
getName :: Node String
getName = nodeName <$> get

-- |Get the current namespace.
getNamespace :: Node String
getNamespace = namespace <$> get

halt :: IO a
halt = do
    E.forever (threadDelay maxBound)
    return (error "halt")

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
       subs <- newTVarIO $ M.empty
       pubs <- newTVarIO $ M.empty
       parameters <- newMVar $ M.empty
       services <- newMVar $ M.empty
       let configuredNode = runReaderT nConf (NodeConfig params' nameMap' conf)
           initialState = NodeState name' namespaceConf masterConf myURI sigStop subs pubs parameters services newts clean
           statefulNode = execStateT configuredNode initialState
#if defined(ghcjs_HOST_OS)
       putMVar myURI "http://"
       let (wait,_port) = (halt,0)
#else
       (wait,_port) <- liftIO $ Slave.runSlave initialState
#endif
       statefulNode >>= flip runReaderT (conf,newts) . RN.runNode name' wait _port


registerService :: (Typeable a,Typeable b) => ServiceName -> (a -> Node b) -> Node ()
registerService name go = do
    svs <- gets services
    requests <- liftIO $ newBoundedChan 10  
    forkNodeIO $ do
        let rec = do
                (request,responsev) <- liftIO $ BC.readChan requests
                response <- go request
                liftIO $ putMVar responsev response 
                rec
        rec
    let service = Service name (DynBoundedChan requests)
    liftIO $ modifyMVar svs $ \m -> return (M.insert name service m,())

callService :: (Typeable a,Typeable b) => ServiceName -> a -> Proxy b -> Node (Maybe b)
callService name request (presponse::Proxy b) = do
    svs <- gets services >>= liftIO . readMVar
    case M.lookup name svs of
        Nothing -> return Nothing
        Just service -> liftIO $ do
            (responsev :: MVar b) <- newEmptyMVar
            ok <- tryWriteDynBoundedChan (serviceRequests service) (request,responsev)
            if ok then
                liftM Just $ takeMVar responsev
                else return Nothing

getParameter'' :: ParamName -> Node (Maybe DynMVar)
getParameter'' name = do
    params <- gets parameters
    ps <- liftIO $ readMVar params
    return $ fmap parameterValue $ M.lookup name ps
        
getParameter' :: ParamName -> Node (Maybe Dynamic)
getParameter' name = do
    mb <- getParameter'' name
    case mb of
        Nothing -> return Nothing
        Just valv -> liftM Just $ liftIO $ readDynMVar valv 
        
getParameter :: Typeable a => ParamName -> Node (Maybe a)
getParameter name = do
    dyn <- getParameter' name
    return $ Control.Monad.join $ fmap fromDynamic dyn 
    
setParameter :: Typeable a => ParamName -> a -> Node ()
setParameter name val = do
    params <- gets parameters
    ps <- liftIO $ readMVar params
    case M.lookup name ps of
        Just p -> do
            let valv = parameterValue p
            liftIO $ tryWriteDynMVar valv val
            return ()
        Nothing -> do
            valv <- liftIO $ newMVar val
            let param = Parameter name (DynMVar valv)
            liftIO $ modifyMVar params $ \ps -> return (M.insert name param ps,())

