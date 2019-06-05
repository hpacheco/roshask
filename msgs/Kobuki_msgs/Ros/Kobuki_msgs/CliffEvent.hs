{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.CliffEvent where
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

data CliffEvent = CliffEvent
    { _sensor :: Word.Word8
    , _state :: Word.Word8
    , _bottom :: Word.Word16
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

sensor_LEFT,sensor_CENTER,sensor_RIGHT :: Word.Word8
sensor_LEFT = 0
sensor_CENTER = 1
sensor_RIGHT = 2

state_FLOOR,state_CLIFF :: Word.Word8
state_FLOOR = 0
state_CLIFF = 1

$(makeLenses ''CliffEvent)

instance RosBinary CliffEvent where
  put obj' = put (_sensor obj') *> put (_state obj') *> put (_bottom obj')
  get = CliffEvent <$> get <*> get <*> get

instance Storable CliffEvent where
  sizeOf _ = sizeOf (P.undefined::Word.Word8) +
             sizeOf (P.undefined::Word.Word8) +
             sizeOf (P.undefined::Word.Word16)
  alignment _ = 8
  peek = SM.runStorable (CliffEvent <$> SM.peek <*> SM.peek <*> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_sensor obj') *> SM.poke (_state obj') *> SM.poke (_bottom obj')

instance MsgInfo CliffEvent where
  sourceMD5 _ = "c5b106efbb1427a94f517c5e05f06295"
  msgTypeName _ = "kobuki_msgs/CliffEvent"

instance D.Default CliffEvent

