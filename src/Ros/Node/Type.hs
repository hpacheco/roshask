{-# LANGUAGE CPP, MultiParamTypeClasses, FlexibleInstances, GADTs, ScopedTypeVariables, 
             ExistentialQuantification, GeneralizedNewtypeDeriving #-}
module Ros.Node.Type where
import Control.Applicative (Applicative(..), (<$>))
import Control.Concurrent (MVar, putMVar,readMVar,killThread)
import Control.Concurrent.STM (atomically, TVar, readTVar, writeTVar,modifyTVar)
import Control.Concurrent.BoundedChan as BC
import Control.Concurrent.Hierarchy
import Control.Concurrent.MVar
import Control.Monad.State
import Control.Monad.Reader
import Data.Dynamic
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.List as List
import Control.Concurrent (ThreadId)
import Control.Concurrent.Chan as C
import Ros.Internal.RosTypes (URI,TopicType(..),TopicName)
import Ros.Internal.Util.ArgRemapping (ParamVal)
import Ros.Internal.Util.AppConfig (ConfigOptions)
import Ros.Topic (Topic)
import Ros.Topic.Util (TIO,forkTIO)
import Ros.Topic.Stats
import Data.Typeable
import Ros.Internal.RosTypes

#if defined(ghcjs_HOST_OS)
#else
import Ros.Graph.Slave (RosSlave(..))
#endif

-- TODO: connect to ROS
data Parameter = Parameter
    { parameterName :: ParamName
    , parameterValue :: DynMVar
    }

-- TODO: connect to ROS
data Service = Service
    { serviceName :: ServiceName
    , serviceRequests :: DynBoundedChan
    }

data Subscription = Subscription { knownPubs :: TVar (Set URI)
                                 , addPub    :: URI -> IO ThreadId
                                 , subType   :: String
                                 , subChan   :: DynBoundedChan
                                 , subTopic  :: DynTopic
                                 , subStats  :: StatMap SubStats
                                 , subCleanup :: TVar (IO ())
                                 }

data DynMVar where
  DynMVar :: Typeable a => MVar a -> DynMVar
  
tryWriteDynMVar :: Typeable a => DynMVar -> a -> IO Bool
tryWriteDynMVar (DynMVar v) a = case cast a of
    Nothing -> return False
    Just b -> modifyMVar v $ \_ -> return (b,True)

readDynMVar :: DynMVar -> IO Dynamic
readDynMVar (DynMVar v) = liftM toDyn $ readMVar v

readDynMVar' :: Typeable a => DynMVar -> IO (Maybe a)
readDynMVar' (DynMVar v) = do
    vv <- readMVar v
    return $ cast vv 

data DynTopic where
  DynTopic :: Typeable a => Topic TIO a -> DynTopic

fromDynTopic :: Typeable a => DynTopic -> Maybe (Topic TIO a)
fromDynTopic (DynTopic t) = gcast t

data DynBoundedChan where
  DynBoundedChan :: Typeable a => BoundedChan a -> DynBoundedChan

flushBoundedChan :: BoundedChan a -> IO ()
flushBoundedChan c = do
    mb <- BC.tryReadChan c
    when (isJust mb) $ flushBoundedChan c
    
flushDynBoundedChan :: DynBoundedChan -> IO ()
flushDynBoundedChan (DynBoundedChan c) = flushBoundedChan c

tryWriteDynBoundedChan :: Typeable a => DynBoundedChan -> a -> IO Bool
tryWriteDynBoundedChan (DynBoundedChan c) v = case cast v of
    Nothing -> return False
    Just v' -> BC.writeChan c v' >> return True

fromDynBoundedChan :: Typeable a => DynBoundedChan -> Maybe (BoundedChan a)
fromDynBoundedChan (DynBoundedChan t) = gcast t

data Publication = Publication { subscribers :: TVar (Set URI)
                               , pubType     :: String
                               , pubPort     :: Int
                               , pubChan     :: DynBoundedChan
                               , pubTopic    :: DynTopic
                               , pubStats    :: StatMap PubStats
                               , pubCleanup  :: TVar (IO ())
                               }

data NodeState = NodeState { nodeName       :: String
                           , namespace      :: String
                           , master         :: URI
                           , nodeURI        :: MVar URI
                           , signalShutdown :: MVar (IO ())
                           , subscriptions  :: TVar (Map String Subscription)
                           , publications   :: TVar (Map String Publication)
                           , parameters     :: MVar (Map String Parameter)
                           , services       :: MVar (Map String Service)
                           , threads        :: ThreadMap
                           , nodeCleanup    :: TVar (IO ()) }



type Params = [(String, ParamVal)]
type Remap = [(String,String)]

data NodeConfig = NodeConfig { nodeParams :: Params
                             , nodeRemaps :: Remap
                             , nodeAppConfig :: ConfigOptions }

-- |A 'Node' carries with it parameters, topic remappings, and some
-- state encoding the status of its subscriptions and publications.
newtype Node a = Node { unNode :: ReaderT NodeConfig (StateT NodeState IO) a }
  deriving (Functor, Applicative, Monad, MonadIO)

instance MonadState NodeState Node where
    get = Node get
    put = Node . put

instance MonadReader NodeConfig Node where
    ask = Node ask
    local f m = Node $ withReaderT f (unNode m)

#if defined(ghcjs_HOST_OS)
getNodeName = nodeName
getMaster = master
getNodeURI = nodeURI
setShutdownAction _ shutdown = return ()
cleanupNode s = return ()
#else
instance RosSlave NodeState where
    getNodeName = nodeName
    setShutdownAction ns a = putMVar (signalShutdown ns) a
    getMaster = master
    getNodeURI = nodeURI
    getSubscriptions st = atomically $ do
            subs <- readTVar $ subscriptions st
            mapM formatSub $ M.toList subs
        where formatSub (name, sub) = let topicType = subType sub
                                      in do stats <- readTVar (subStats sub)
                                            stats' <- mapM statSnapshot . 
                                                      M.toList $
                                                      stats
                                            return (name, topicType, stats')
    getPublications st = atomically $ do
            pubs <- readTVar $ publications st
            mapM formatPub $ M.toList pubs
        where formatPub (name, pub) = let topicType = pubType pub
                                      in do stats <- readTVar (pubStats pub)
                                            stats' <- mapM statSnapshot .
                                                      M.toList $
                                                      stats
                                            return (name, topicType, stats')
    --hpacheco: ignore publishers from the same node
    publisherUpdate ns name uris = 
        let act = readMVar (nodeURI ns) >>= \nodeuri -> do
                cleans <- join.atomically $ do
                      subs <- readTVar $ subscriptions ns
                      case M.lookup name subs of
                        Nothing -> return (return [])
                        Just sub -> do
                            let add = addPub sub >=> \t -> return [(t,subCleanup sub)]
                            known <- readTVar (knownPubs sub) 
                            (act',known') <- foldM (connectToPub add)
                                (return [], known)
                                (List.delete nodeuri uris)
                            writeTVar (knownPubs sub) known'
                            return act'
                forM_ cleans $ \(t,clean) -> atomically $ modifyTVar clean (>> killThread t)
        in act
    getTopicPortTCP st t = do
        pubs <- atomically $ readTVar $ publications st
        return $ (fmap pubPort) $ M.lookup t pubs
    stopNode st = do
        clean <- atomically $ readTVar $ nodeCleanup st
        clean
        killThreadHierarchy $ threads st
        subs <- atomically $ readTVar $ subscriptions st
        mapM_ (atomically . readTVar . subCleanup . snd) $ M.toList $ subs
        pubs <- atomically $ readTVar $ publications st
        mapM_ (atomically . readTVar . pubCleanup . snd) $ M.toList $ pubs
#endif

formatSubscription :: NodeState -> TopicName -> Subscription -> IO (TopicType, [(URI, SubStats)])
formatSubscription st name sub = atomically $ formatSub (name,sub)
        where formatSub (name, sub) = let topicType = subType sub
                                      in do stats <- readTVar (subStats sub)
                                            stats' <- mapM statSnapshot . 
                                                      M.toList $
                                                      stats
                                            return (topicType, stats')

formatPublication :: NodeState -> TopicName -> Publication -> IO (TopicType, [(URI, PubStats)])
formatPublication st name pub = atomically $ formatPub (name,pub)
        where formatPub (name, pub) = let topicType = pubType pub
                                      in do stats <- readTVar (pubStats pub)
                                            stats' <- mapM statSnapshot .
                                                      M.toList $
                                                      stats
                                            return (topicType, stats')

-- If a given URI is not a part of a Set of known URIs, add an action
-- to effect a subscription to an accumulated action and add the URI
-- to the Set.
connectToPub :: Monad m => 
                (URI -> IO [a]) -> (IO [a], Set URI) -> URI -> m (IO [a], Set URI)
connectToPub doSub (act, known) uri = if S.member uri known
                                      then return (act, known)
                                      else let known' = S.insert uri known
                                           in return (doSub uri >>= \t1 -> act >>= \t2 -> return (t1++t2), known')

addCleanup :: IO () -> Node ()
addCleanup m = do
    c <- gets nodeCleanup
    liftIO $ atomically $ modifyTVar c (>> m)