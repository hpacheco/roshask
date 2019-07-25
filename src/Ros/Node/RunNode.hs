{-# LANGUAGE ScopedTypeVariables #-}

module Ros.Node.RunNode (runNode,registerPublicationNode,registerSubscriptionNode) where
import Control.Concurrent (readMVar, killThread)
import qualified Control.Concurrent.SSem as Sem
import qualified Control.Exception as E
import Control.Concurrent.BoundedChan
import Control.Monad.Reader (runReaderT,ask,asks)
import Control.Monad.State (get,gets)
import Control.Monad.IO.Class
import System.Posix.Signals (installHandler, Handler(..), sigINT)
import Ros.Internal.RosTypes
import Ros.Internal.Util.AppConfig (Config, debug)
import Ros.Graph.Master
import Ros.Graph.Slave
import Ros.Internal.Util.AppConfig
import Ros.Node.Type
import Ros.Topic (Topic,runTopic)
import Ros.Topic.Util (TIO)
import qualified Data.Map as Map
import Data.Typeable (gcast)

import Data.Maybe
import Data.Typeable
import Control.Monad
import GHC.Conc

-- Inform the master that we are publishing a particular topic.
registerPublication :: RosSlave n => 
                       String -> n -> String -> String -> 
                       (TopicName, TopicType, a) -> Config ()
registerPublication name _n master uri (tname, ttype, _) = orErrorConfig_ "Warning: cannot register publication on master" $ 
    do debug $ "Registering publication of "++ttype++" on topic "++
               tname++" on master "++master
       _subscribers <- liftIO $ registerPublisher master name tname ttype uri
       return ()

-- Inform the master that we are subscribing to a particular topic.
registerSubscription :: RosSlave n =>
                        String -> n -> String -> String -> 
                        (TopicName, TopicType, a) -> Config ()
registerSubscription name n master uri (tname, ttype, _) = orErrorConfig_ "Warning: cannot register subscription on master" $ 
    do debug $ "Registering subscription to "++tname++" for "++ttype
       (r,_,publishers) <- liftIO $ registerSubscriber master name tname ttype uri
       if r == 1 
         then liftIO $ publisherUpdate n tname publishers
         else error "Failed to register subscriber with master"
       return ()

-- Redirect local publishers to local subscribers
registerLocalSubscription :: (String,(Publication,Subscription)) -> Config ()
registerLocalSubscription (topicname,(pub,sub)) = do
    redirectChan (pubTopic pub) (subChan sub)
  where
    redirectChan :: DynTopic -> DynBoundedChan -> Config ()
    redirectChan (DynTopic from) (DynBoundedChan (to::BoundedChan b)) = 
        case gcast from of
            Nothing -> do
                debug $ "Warning: Topic " ++ topicname ++ "published with type " ++ show (typeOf from) ++ " but subscribed with type " ++ show (typeOf to)
                return ()
            Just (from'::Topic TIO b) -> do
                --liftIO $ putStrLn $ "redirecting " ++ topicname
                let go t = do { (x,t') <- runTopic t; liftIO (writeChan to x); go t' }
                _ <- forkConfig $ do
                    (_,ts) <- ask
                    liftIO $ runReaderT (go from') ts
                return ()

--registerNode :: String -> NodeState -> Config ()
--registerNode name n = 
--    do uri <- liftIO $ readMVar (getNodeURI n)
--       let master = getMaster n
--       debug $ "Starting node "++name++" at " ++ uri
--       pubs <- liftIO $ getPublications n
--       subs <- liftIO $ getSubscriptions n
--       mapM_ (registerPublication name n master uri) pubs
--       mapM_ (registerSubscription name n master uri) subs
--       --liftIO $ putStrLn $ "pubs " ++ show (Map.keys $ publications n)
--       --liftIO $ putStrLn $ "subs " ++ show (Map.keys $ subscriptions n)
--       let pubsubs = Map.intersectionWithKey (\k p s -> (p,s)) (publications n) (subscriptions n)
--       mapM_ (registerLocalSubscription) (Map.toList pubsubs)

configNode :: Config a -> Node a
configNode cfg = do
    ts <- gets threads
    opts <- asks nodeAppConfig
    liftIO $ runReaderT cfg (opts,ts)

registerSubscriptionNode :: TopicName -> Subscription -> Node ()
registerSubscriptionNode name sub = do
    n <- get
    uri <- liftIO $ readMVar (getNodeURI n)
    let master = getMaster n
    let nodename = getNodeName n
    (typ,stats) <- liftIO $ formatSubscription n name sub
    configNode $ registerSubscription nodename n master uri (name,typ,stats)
    case Map.lookup name (publications n) of
        Nothing -> return ()
        Just pub -> configNode $ registerLocalSubscription (name,(pub,sub))

registerPublicationNode :: TopicName -> Publication -> Node ()
registerPublicationNode name pub = do
    n <- get
    uri <- liftIO $ readMVar (getNodeURI n)
    let master = getMaster n
    let nodename = getNodeName n
    (typ,stats) <- liftIO $ formatPublication n name pub
    configNode $ registerPublication nodename n master uri (name,typ,stats)
    case Map.lookup name (subscriptions n) of
        Nothing -> return ()
        Just sub -> configNode $ registerLocalSubscription (name,(pub,sub))

-- |Run a ROS Node with the given name. Returns when the Node has
-- shutdown either by receiving an interrupt signal (e.g. Ctrl-C) or
-- because the master told it to stop.
runNode :: String -> NodeState -> Config ()
runNode name s = do (wait, _port) <- liftIO $ runSlave s
                    --registerNode name s
                    debug "Spinning"
                    allDone <- liftIO $ Sem.new 0
                    let ignoreEx :: E.SomeException -> IO ()
                        ignoreEx _ = return ()
                        shutdown = do putStrLn "Shutting down"
                                      (cleanupNode s) `E.catch` ignoreEx
                                      Sem.signal allDone
                    liftIO $ setShutdownAction s shutdown
                    _ <- liftIO $ 
                         installHandler sigINT (CatchOnce shutdown) Nothing
                    t <- liftIO . forkIO $ wait >> Sem.signal allDone
                    liftIO $ Sem.wait allDone
                    liftIO $ killThread t `E.catch` ignoreEx
