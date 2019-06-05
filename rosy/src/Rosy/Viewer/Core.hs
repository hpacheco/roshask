module Rosy.Viewer.Core where

import Rosy.Robot.State
import Rosy.Viewer.State

import Graphics.Gloss.Interface.IO.Game
import Control.Concurrent.STM

runViewer :: WorldState -> IO ()
runViewer w = do
    let display = InWindow "rosy-simulator" (800,800) (0,0)
    playIO display (greyN 0.5) 60 w drawIO eventIO timeIO

drawIO :: WorldState -> IO Picture
drawIO w = return Blank

eventIO :: Event -> WorldState -> IO WorldState
eventIO (EventKey (Char '0') kst _ _) w = reactButton button0 kst w
eventIO (EventKey (Char '1') kst _ _) w = reactButton button1 kst w
eventIO (EventKey (Char '2') kst _ _) w = reactButton button2 kst w
eventIO e w = return w

keyStateToBool :: KeyState -> Bool
keyStateToBool Down = True
keyStateToBool Up = False

reactButton :: (RobotState -> RobotEventState) -> KeyState -> WorldState -> IO WorldState
reactButton getButton kst w = atomically $ changeRobotEventState (getButton $ robot w) (keyStateToBool kst) >> return w

timeIO :: Float -> WorldState -> IO WorldState
timeIO t w = return w
    

