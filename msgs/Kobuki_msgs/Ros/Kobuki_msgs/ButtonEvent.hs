{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.ButtonEvent where
import qualified Prelude as P
import Prelude ((.), (+), (*))
import qualified Data.Typeable as T
import Control.Applicative
import Ros.Internal.RosBinary
import Ros.Internal.Msg.MsgInfo
import qualified GHC.Generics as G
import qualified Data.Default.Generics as D
import qualified Data.Word as Word
import Foreign.Storable (Storable(..))
import qualified Ros.Internal.Util.StorableMonad as SM
import Lens.Family.TH (makeLenses)
import Lens.Family (view, set)

data ButtonEvent = ButtonEvent
    { _button :: Word.Word8
    , _state :: Word.Word8
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

button_Button0,button_Button1,button_Button2 :: Word.Word8
button_Button0 = 0
button_Button1 = 1
button_Button2 = 2

state_RELEASED,state_PRESSED :: Word.Word8
state_RELEASED = 0
state_PRESSED = 1

$(makeLenses ''ButtonEvent)

instance RosBinary ButtonEvent where
  put obj' = put (_button obj') *> put (_state obj')
  get = ButtonEvent <$> get <*> get

instance Storable ButtonEvent where
  sizeOf _ = sizeOf (P.undefined::Word.Word8) +
             sizeOf (P.undefined::Word.Word8)
  alignment _ = 8
  peek = SM.runStorable (ButtonEvent <$> SM.peek <*> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_button obj') *> SM.poke (_state obj')

instance MsgInfo ButtonEvent where
  sourceMD5 _ = "49eca512765dbdec759a79083ffcec8d"
  msgTypeName _ = "kobuki_msgs/ButtonEvent"

instance D.Default ButtonEvent

