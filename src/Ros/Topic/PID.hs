-- |PID related functions for 'Topic's.
module Ros.Topic.PID where
import Control.Applicative
import Ros.Topic
import Ros.Topic.Util
import qualified Ros.Util.PID as P
import Control.Monad.Trans

-- |@pidUniform2 kp ki kd setpoint t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the setpoints produced by
-- 'Topic' @setpoint@ using the PID gains @kp@, @ki@, and @kd@. The
-- interval between samples produced by the 'Topic' is assumed to be
-- 1.
pidUniform2 :: Fractional a => a -> a -> a -> Topic TIO a -> Topic TIO a -> 
                (Topic TIO a)
pidUniform2 kp ki kd setpoint t = Topic $ do
        controller <- uncurry <$> lift (P.pidUniformIO kp ki kd)
        runTopic . join $ (lift . controller) <$> everyNew setpoint t

-- |@pidUniform kp ki kd setpoint t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the given setpoint using
-- the PID gains @kp@, @ki@, and @kd@. The interval between samples
-- produced by the 'Topic' is assumed to be 1.
pidUniform :: Fractional a => a -> a -> a -> a -> Topic TIO a -> Topic TIO a
pidUniform kp ki kd setpoint t = 
  Topic $ do controller <- ($ setpoint) <$> lift (P.pidUniformIO kp ki kd)
             runTopic . join $ (lift . controller) <$> t

-- |@pidFixed2 kp ki kd setpoint dt t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the setpoints produced by
-- 'Topic' @setpoint@ using the PID gains @kp@, @ki@, and @kd@, along
-- with an assumed fixed time interval, @dt@, between samples.
pidFixed2 :: Fractional a => a -> a -> a -> a -> Topic TIO a -> Topic TIO a -> 
             (Topic TIO a)
pidFixed2 kp ki kd dt setpoint t = Topic $ do
        controller <- uncurry <$> lift (P.pidFixedIO kp ki kd dt)
        runTopic . join $ (lift . controller) <$> everyNew setpoint t


-- |@pidFixed kp ki kd setpoint dt t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the given setpoint using
-- the PID gains @kp@, @ki@, and @kd@, along with an assumed fixed
-- time interval, @dt@, between samples.
pidFixed :: Fractional a => a -> a -> a -> a -> a -> Topic TIO a -> Topic TIO a
pidFixed kp ki kd setpoint dt t = 
  Topic $ do controller <- ($ setpoint) <$> lift (P.pidFixedIO kp ki kd dt)
             runTopic . join $ (lift . controller) <$> t

-- |@pidTimed2 kp ki kd setpoint t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the setpoints produced by
-- 'Topic' @setpoint@ using the PID gains @kp@, @ki@, and @kd@. The
-- system clock is checked for each value produced by the input
-- 'Topic' to determine the actual sampling rate.
pidTimed2 :: Fractional a => a -> a -> a -> Topic TIO a -> Topic TIO a -> 
             (Topic TIO a)
pidTimed2 kp ki kd setpoint t = Topic $ do
        controller <- uncurry <$> lift (P.pidTimedIO kp ki kd)
        runTopic . join $ (lift . controller) <$> everyNew setpoint t

-- |@pidTimed kp ki kd setpoint t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the given setpoint using
-- the PID gains @kp@, @ki@, and @kd@. The system clock is checked for
-- each value produced by the input 'Topic' to determine the actual
-- sampling rate.
pidTimed :: Fractional a => a -> a -> a -> a -> Topic TIO a -> Topic TIO a
pidTimed kp ki kd setpoint t = 
  Topic $ do controller <- ($ setpoint) <$> lift (P.pidTimedIO kp ki kd)
             runTopic . join $ (lift . controller) <$> t


-- |@pidStamped2 kp ki kd setpoint t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the given setpoint using
-- the PID gains @kp@, @ki@, and @kd@. Values produced by the 'Topic'
-- @t@ must be paired with a timestamp and thus have the form
-- (timeStamp, sample).
pidStamped2 :: Fractional a => a -> a -> a -> Topic TIO a -> Topic TIO (a,a) -> 
                (Topic TIO a)
pidStamped2 kp ki kd setpoint t = Topic $ do
        controller <- uncurry <$> lift (P.pidWithTimeIO kp ki kd)
        runTopic . join $ (lift . controller) <$> everyNew setpoint t

-- |@pidStamped kp ki kd setpoint t@ runs a PID controller that
-- transforms 'Topic' @t@ of process outputs into a 'Topic' of control
-- signals designed to steer the output to the given setpoint using
-- the PID gains @kp@, @ki@, and @kd@. Values produced by the 'Topic'
-- @t@ must be paired with a timestamp and thuse have the form
-- (timeStamp, sample).
pidStamped :: Fractional a => a -> a -> a -> a -> Topic TIO (a,a) -> Topic TIO a
pidStamped kp ki kd setpoint t =
  Topic $ do controller <- ($ setpoint) <$> lift (P.pidWithTimeIO kp ki kd)
             runTopic . join $ (lift . controller) <$> t
