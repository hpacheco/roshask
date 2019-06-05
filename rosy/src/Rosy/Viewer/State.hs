{-# LANGUAGE DeriveGeneric #-}

module Rosy.Viewer.State where

import Rosy.Robot.State

import Ros.Node
import Ros.Rate
import Ros.Topic as Topic hiding (fst,snd)
import Ros.Topic.Util as Topic 
import Ros.Kobuki_msgs.Led as Led
import Ros.Kobuki_msgs.Sound as Sound
import Ros.Kobuki_msgs.BumperEvent as BumperEvent
import Ros.Kobuki_msgs.ButtonEvent as ButtonEvent
import Ros.Kobuki_msgs.CliffEvent as CliffEvent
import Ros.Nav_msgs.Odometry as Odometry

import Control.Concurrent.STM
import Data.Typeable
import GHC.Generics as G
import GHC.Conc

data WorldState = WorldState
    { robot :: RobotState -- static
    } deriving (Typeable, G.Generic)