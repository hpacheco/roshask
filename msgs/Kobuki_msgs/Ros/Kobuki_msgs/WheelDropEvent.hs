{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.WheelDropEvent where
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

data WheelDropEvent = WheelDropEvent
    { _wheel :: Word.Word8
    , _state :: Word.Word8
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

wheel_LEFT,wheel_RIGHT :: Word.Word8
wheel_LEFT = 0
wheel_RIGHT = 1

state_RAISED,state_DROPPED :: Word.Word8
state_RAISED = 0
state_DROPPED = 1

$(makeLenses ''WheelDropEvent)

instance RosBinary WheelDropEvent where
  put obj' = put (_wheel obj') *> put (_state obj')
  get = WheelDropEvent <$> get <*> get

instance Storable WheelDropEvent where
  sizeOf _ = sizeOf (P.undefined::Word.Word8) +
             sizeOf (P.undefined::Word.Word8)
  alignment _ = 8
  peek = SM.runStorable (WheelDropEvent <$> SM.peek <*> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_wheel obj') *> SM.poke (_state obj')

instance MsgInfo WheelDropEvent where
  sourceMD5 _ = "e102837d89384d67669a0df86b63f33b"
  msgTypeName _ = "kobuki_msgs/WheelDropEvent"

instance D.Default WheelDropEvent

