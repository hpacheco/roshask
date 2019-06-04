{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.BumperEvent where
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

data BumperEvent = BumperEvent
    { _bumper :: Word.Word8
    , _state :: Word.Word8
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

bumper_LEFT = 0
bumper_CENTER = 1
bumper_RIGHT = 2

state_RELEASED = 0
state_PRESSED = 1

$(makeLenses ''BumperEvent)

instance RosBinary BumperEvent where
  put obj' = put (_bumper obj') *> put (_state obj')
  get = BumperEvent <$> get <*> get

instance Storable BumperEvent where
  sizeOf _ = sizeOf (P.undefined::Word.Word8) +
             sizeOf (P.undefined::Word.Word8)
  alignment _ = 8
  peek = SM.runStorable (BumperEvent <$> SM.peek <*> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_bumper obj') *> SM.poke (_state obj')

instance MsgInfo BumperEvent where
  sourceMD5 _ = "ffe360cd50f14f9251d9844083e72ac5"
  msgTypeName _ = "kobuki_msgs/BumperEvent"

instance D.Default BumperEvent

