{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
module Ros.Kobuki_msgs.Sound where
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

data Sound = Sound
    { _value :: Word.Word8
    } deriving (P.Show, P.Eq, P.Ord, T.Typeable, G.Generic)

value_ON,value_OFF,value_RECHARGE,value_BUTTON,value_ERROR,value_CLEANINGSTART,value_CLEANINGEND :: Word.Word8
value_ON = 0
value_OFF = 1
value_RECHARGE = 2
value_BUTTON = 3
value_ERROR = 4
value_CLEANINGSTART = 5
value_CLEANINGEND = 6

$(makeLenses ''Sound)

instance RosBinary Sound where
  put obj' = put (_value obj') 
  get = Sound <$> get 

instance Storable Sound where
  sizeOf _ = sizeOf (P.undefined::Word.Word8)
  alignment _ = 8
  peek = SM.runStorable (Sound <$> SM.peek)
  poke ptr' obj' = SM.runStorable store' ptr'
    where store' = SM.poke (_value obj')

instance MsgInfo Sound where
  sourceMD5 _ = "dfeab0daae67749c426c1db741a4f420"
  msgTypeName _ = "kobuki_msgs/Sound"

instance D.Default Sound

