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
import Ros.Graph.Master
import Ros.Graph.Slave
import Ros.Internal.Util.AppConfig
import Ros.Node.Type
import Ros.Topic (Topic,runTopic)
import qualified Data.Map as Map
import Data.Typeable (gcast)

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
            Nothing -> return ()
            Just (from'::Topic IO b) -> do
                let go t = do { (x,t') <- runTopic t; writeChan to x; go t' }
                _ <- forkConfig $ liftIO $ go from'
                return ()

registerNode :: String -> NodeState -> Config ()
registerNode name n = 
    do uri <- liftIO $ readMVar (getNodeURI n)
       let master = getMaster n
       debug $ "Starting node "++name++" at " ++ uri
       pubs <- liftIO $ getPublications n
       subs <- liftIO $ getSubscriptions n
       mapM_ (registerPublication name n master uri) pubs
       mapM_ (registerSubscription name n master uri) subs
       let pubsubs = Map.intersectionWithKey (\k p s -> (p,s)) (publications n) (subscriptions n)
       mapM_ (registerLocalSubscription) (Map.toList pubsubs)

-- |Run a ROS Node with the given name. Returns when the Node has
-- shutdown either by receiving an interrupt signal (e.g. Ctrl-C) or
-- because the master told it to stop.
runNode :: String -> NodeState -> Config ()
runNode name s = do (wait, _port) <- liftIO $ runSlave s
                    registerNode name s
                    debug "Spinning"
                    allDone <- liftIO $ Sem.new 0
                    let ignoreEx :: E.SomeException -> IO ()
                        ignoreEx _ = return ()
                        shutdown = do putStrLn "Shutting down"
                                      cleanupNode s `E.catch` ignoreEx
                                      Sem.signal allDone
                    liftIO $ setShutdownAction s shutdown
                    _ <- liftIO $ 
                         installHandler sigINT (CatchOnce shutdown) Nothing
                    t <- liftIO . forkIO $ wait >> Sem.signal allDone
                    liftIO $ Sem.wait allDone
                    liftIO $ killThread t `E.catch` ignoreEx
