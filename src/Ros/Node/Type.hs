{-# LANGUAGE CPP, MultiParamTypeClasses, FlexibleInstances, GADTs,
             ExistentialQuantification, GeneralizedNewtypeDeriving #-}
module Ros.Node.Type where
import Control.Applicative (Applicative(..), (<$>))
import Control.Concurrent (MVar, putMVar,readMVar,killThread)
import Control.Concurrent.STM (atomically, TVar, readTVar, writeTVar,modifyTVar)
import Control.Concurrent.BoundedChan
import Control.Concurrent.Hierarchy
import Control.Monad.State
import Control.Monad.Reader
import Data.Dynamic
import Data.Map (Map)
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import qualified Data.List as List
import Control.Concurrent (ThreadId)
import Control.Concurrent.Chan
import Ros.Internal.RosTypes (URI,TopicType(..),TopicName)
import Ros.Internal.Util.ArgRemapping (ParamVal)
import Ros.Internal.Util.AppConfig (ConfigOptions)
import Ros.Topic (Topic)
import Ros.Topic.Util (TIO)
import Ros.Topic.Stats
import Data.Typeable

#if defined(ghcjs_HOST_OS)
#else
import Ros.Graph.Slave (RosSlave(..))
#endif

data Subscription = Subscription { knownPubs :: TVar (Set URI)
                                 , addPub    :: URI -> IO ThreadId
                                 , subType   :: String
                                 , subChan   :: DynBoundedChan
                                 , subTopic  :: DynTopic
                                 , subStats  :: StatMap SubStats
                                 , subCleanup :: TVar (IO ()) }

data DynTopic where
  DynTopic :: Typeable a => Topic TIO a -> DynTopic

fromDynTopic :: Typeable a => DynTopic -> Maybe (Topic TIO a)
fromDynTopic (DynTopic t) = gcast t

data DynBoundedChan where
  DynBoundedChan :: Typeable a => BoundedChan a -> DynBoundedChan

fromDynBoundedChan :: Typeable a => DynBoundedChan -> Maybe (BoundedChan a)
fromDynBoundedChan (DynBoundedChan t) = gcast t

data Publication = Publication { subscribers :: TVar (Set URI)
                               , pubType     :: String
                               , pubPort     :: Int
                               , pubChan     :: DynBoundedChan
                               , pubTopic    :: DynTopic
                               , pubStats    :: StatMap PubStats
                               , pubCleanup  :: TVar (IO ()) }

data NodeState = NodeState { nodeName       :: String
                           , namespace      :: String
                           , master         :: URI
                           , nodeURI        :: MVar URI
                           , signalShutdown :: MVar (IO ())
                           , subscriptions  :: Map String Subscription
                           , publications   :: Map String Publication
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

instance RosSlave NodeState where
    getMaster = master
    getNodeName = nodeName
    getNodeURI = nodeURI
    getSubscriptions = atomically . mapM formatSub . M.toList . subscriptions
        where formatSub (name, sub) = let topicType = subType sub
                                      in do stats <- readTVar (subStats sub)
                                            stats' <- mapM statSnapshot . 
                                                      M.toList $
                                                      stats
                                            return (name, topicType, stats')
    getPublications = atomically . mapM formatPub . M.toList . publications
        where formatPub (name, pub) = let topicType = pubType pub
                                      in do stats <- readTVar (pubStats pub)
                                            stats' <- mapM statSnapshot .
                                                      M.toList $
                                                      stats
                                            return (name, topicType, stats')
    --hpacheco: ignore publishers from the same node
    publisherUpdate ns name uris = 
        let act = readMVar (nodeURI ns) >>= \nodeuri -> do
                cleans <- join.atomically $
                      case M.lookup name (subscriptions ns) of
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
    getTopicPortTCP = ((pubPort <$> ) .) . flip M.lookup . publications
    setShutdownAction ns a = putMVar (signalShutdown ns) a
    stopNode st = do
        clean <- atomically $ readTVar $ nodeCleanup st
        clean
        killThreadHierarchy $ threads st
        mapM_ (atomically . readTVar . subCleanup . snd) $ M.toList $ subscriptions st
        mapM_ (atomically . readTVar . pubCleanup . snd) $ M.toList $ publications st

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