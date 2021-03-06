module Halogen.Query.HalogenM where

import Prelude

import Control.Applicative.Free (FreeAp, liftFreeAp, hoistFreeAp)
import Control.Monad.Error.Class (class MonadThrow, throwError)
import Control.Monad.Free (Free, hoistFree, liftF)
import Control.Monad.Reader.Class (class MonadAsk, ask)
import Control.Monad.Rec.Class (class MonadRec, tailRecM, Step(..))
import Control.Monad.State.Class (class MonadState)
import Control.Monad.Trans.Class (class MonadTrans)
import Control.Monad.Writer.Class (class MonadTell, tell)
import Control.Parallel.Class (class Parallel)
import Data.Bifunctor (lmap)
import Data.Map (Map)
import Data.Maybe (Maybe)
import Data.Newtype (class Newtype, over)
import Data.Symbol (class IsSymbol, SProxy)
import Data.Traversable (traverse)
import Data.Tuple (Tuple)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (class MonadEffect, liftEffect)
import Effect.Exception (Error)
import Halogen.Data.Slot (Slot, SlotStorage)
import Halogen.Data.Slot as Slot
import Halogen.Query.EventSource as ES
import Halogen.Query.ForkF as FF
import Halogen.Query.Input (RefLabel)
import Prim.Row as Row
import Unsafe.Coerce (unsafeCoerce)
import Web.DOM (Element)

newtype SubscriptionId = SubscriptionId Int

derive newtype instance eqSubscriptionId :: Eq SubscriptionId
derive newtype instance ordSubscriptionId :: Ord SubscriptionId

newtype UnpackQuery ps g o f b =
  UnpackQuery (forall slot m. Applicative m => (slot g o -> m b) -> SlotStorage ps slot -> m (f b))

type ChildQuery' ps g o a f b =
  { unpack :: UnpackQuery ps g o f b
  , query :: g b
  , reply :: f b -> a
  }

data ChildQuery (ps :: # Type) a

mkChildQuery :: forall ps g o a f b. ChildQuery' ps g o a f b -> ChildQuery ps a
mkChildQuery = unsafeCoerce

unChildQuery :: forall ps a r. (forall g o f b. ChildQuery' ps g o a f b -> r) -> ChildQuery ps a -> r
unChildQuery = unsafeCoerce

-- | The Halogen component algebra
data HalogenF s act ps o m a
  = State (s -> Tuple a s)
  | Subscribe (SubscriptionId -> ES.EventSource m act) (SubscriptionId -> a)
  | Unsubscribe SubscriptionId a
  | Lift (m a)
  | ChildQuery (ChildQuery ps a)
  | Raise o a
  | Par (HalogenAp s act ps o m a)
  | Fork (FF.Fork (HalogenM' s act ps o m) a)
  | GetRef RefLabel (Maybe Element -> a)

instance functorHalogenF :: Functor m => Functor (HalogenF s act ps o m) where
  map f = case _ of
    State k -> State (lmap f <<< k)
    Subscribe fes a -> Subscribe fes (map f a)
    Unsubscribe sid a -> Unsubscribe sid (f a)
    Lift q -> Lift (map f q)
    ChildQuery cq -> ChildQuery (unChildQuery (\cq' -> mkChildQuery $ cq' { reply = cq'.reply >>> f }) cq)
    Raise o a -> Raise o (f a)
    Par pa -> Par (map f pa)
    Fork fa -> Fork (map f fa)
    GetRef p k -> GetRef p (map f k)

newtype HalogenAp s act ps o m a = HalogenAp (FreeAp (HalogenM' s act ps o m) a)

derive instance newtypeHalogenAp :: Newtype (HalogenAp s f ps o m a) _
derive newtype instance functorHalogenAp :: Functor (HalogenAp s f ps o m)
derive newtype instance applyHalogenAp :: Apply (HalogenAp s f ps o m)
derive newtype instance applicativeHalogenAp :: Applicative (HalogenAp s f ps o m)

newtype HalogenM' s act ps o m a = HalogenM (Free (HalogenF s act ps o m) a)

type HalogenM s act = HalogenM' s (act Unit)

derive newtype instance functorHalogenM :: Functor (HalogenM' s act ps o m)
derive newtype instance applyHalogenM :: Apply (HalogenM' s act ps o m)
derive newtype instance applicativeHalogenM :: Applicative (HalogenM' s act ps o m)
derive newtype instance bindHalogenM :: Bind (HalogenM' s act ps o m)
derive newtype instance monadHalogenM :: Monad (HalogenM' s act ps o m)

instance monadEffectHalogenM :: MonadEffect m => MonadEffect (HalogenM' s act ps o m) where
  liftEffect eff = HalogenM $ liftF $ Lift $ liftEffect eff

instance monadAffHalogenM :: MonadAff m => MonadAff (HalogenM' s act ps o m) where
  liftAff aff = HalogenM $ liftF $ Lift $ liftAff aff

instance parallelHalogenM :: Parallel (HalogenAp s act ps o m) (HalogenM' s act ps o m) where
  parallel = HalogenAp <<< liftFreeAp
  sequential = HalogenM <<< liftF <<< Par

instance monadTransHalogenM :: MonadTrans (HalogenM' s act ps o) where
  lift m = HalogenM $ liftF $ Lift m

instance monadRecHalogenM :: MonadRec (HalogenM' s act ps o m) where
  tailRecM k a = k a >>= go
    where
    go (Loop x) = tailRecM k x
    go (Done y) = pure y

instance monadStateHalogenM :: MonadState s (HalogenM' s act ps o m) where
  state = HalogenM <<< liftF <<< State

instance monadAskHalogenM :: MonadAsk r m => MonadAsk r (HalogenM' s act ps o m) where
  ask = HalogenM $ liftF $ Lift $ ask

instance monadTellHalogenM :: MonadTell w m => MonadTell w (HalogenM' s act ps o m) where
  tell = HalogenM <<< liftF <<< Lift <<< tell

instance monadThrowHalogenM :: MonadThrow e m => MonadThrow e (HalogenM' s act ps o m) where
  throwError = HalogenM <<< liftF <<< Lift <<< throwError

-- | Subscribes a component to an `EventSource`.
subscribe :: forall s act ps o m. ES.EventSource m act -> HalogenM' s act ps o m SubscriptionId
subscribe es = HalogenM $ liftF $ Subscribe (\_ -> es) identity

-- | An alternative to `subscribe`, intended for subscriptions that unsubscribe
-- | themselves. Instead of returning the `SubscriptionId` from `subscribe'`, it
-- | is passed into an `EventSource` constructor. This allows emitted queries
-- | to include the `SubscriptionId`, rather than storing it in the state of the
-- | component.
subscribe' :: forall s act ps o m. (SubscriptionId -> ES.EventSource m act) -> HalogenM' s act ps o m Unit
subscribe' esc = HalogenM $ liftF $ Subscribe esc (const unit)

unsubscribe :: forall s act ps o m. SubscriptionId -> HalogenM' s act ps o m Unit
unsubscribe sid = HalogenM $ liftF $ Unsubscribe sid unit

-- | Sends a query to a child of a component at the specified slot.
query
  :: forall s act o m sym px ps f o' p a
   . Row.Cons sym (Slot f o' p) px ps
  => IsSymbol sym
  => Ord p
  => SProxy sym
  -> p
  -> f a
  -> HalogenM' s act ps o m (Maybe a)
query sym p q = HalogenM $ liftF $ ChildQuery $ mkChildQuery
  { unpack: UnpackQuery \k -> Slot.lookup sym p >>> traverse k
  , query: q
  , reply: identity
  }

-- | Sends a query to all children of a component at a given slot label.
queryAll
  :: forall s act o m sym px ps f o' p a
   . Row.Cons sym (Slot f o' p) px ps
  => IsSymbol sym
  => Ord p
  => SProxy sym
  -> f a
  -> HalogenM' s act ps o m (Map p a)
queryAll sym q = HalogenM $ liftF $ ChildQuery $ mkChildQuery
  { unpack: UnpackQuery \k -> Slot.slots sym >>> traverse k
  , query: q
  , reply: identity
  }

getRef :: forall s act ps o m. RefLabel -> HalogenM' s act ps o m (Maybe Element)
getRef p = HalogenM $ liftF $ GetRef p identity

-- | Raises an output message for the component.
raise :: forall s act ps o m. o -> HalogenM' s act ps o m Unit
raise o = HalogenM $ liftF $ Raise o unit

fork :: forall s act ps o m a. MonadAff m => HalogenM' s act ps o m a -> HalogenM' s act ps o m (Error -> m Unit)
fork a = map liftAff <$> HalogenM (liftF $ Fork $ FF.fork a)

imapState
  :: forall s s' act ps o m
   . (s -> s')
  -> (s' -> s)
  -> HalogenM' s act ps o m
  ~> HalogenM' s' act ps o m
imapState f f' (HalogenM h) = HalogenM (hoistFree go h)
  where
  go :: HalogenF s act ps o m ~> HalogenF s' act ps o m
  go = case _ of
    State fs -> State (map f <<< fs <<< f')
    Subscribe fes a -> Subscribe fes a
    Unsubscribe sid a -> Unsubscribe sid a
    Lift q -> Lift q
    ChildQuery cq -> ChildQuery cq
    Raise o a -> Raise o a
    Par p -> Par (over HalogenAp (hoistFreeAp (imapState f f')) p)
    Fork fo -> Fork (FF.hoistFork (imapState f f') fo)
    GetRef p k -> GetRef p k

mapAction
  :: forall s act act' ps o m
   . Functor m
  => (act -> act')
  -> HalogenM' s act ps o m
  ~> HalogenM' s act' ps o m
mapAction f (HalogenM h) = HalogenM (hoistFree go h)
  where
  go :: HalogenF s act ps o m ~> HalogenF s act' ps o m
  go = case _ of
    State fs -> State fs
    Subscribe fes a -> Subscribe (map f <<< fes) a
    Unsubscribe sid a -> Unsubscribe sid a
    Lift q -> Lift q
    ChildQuery cq -> ChildQuery cq
    Raise o a -> Raise o a
    Par p -> Par (over HalogenAp (hoistFreeAp (mapAction f)) p)
    Fork fo -> Fork (FF.hoistFork (mapAction f) fo)
    GetRef p k -> GetRef p k

mapOutput
  :: forall s act ps o o' m
   . (o -> o')
  -> HalogenM' s act ps o  m
  ~> HalogenM' s act ps o' m
mapOutput f (HalogenM h) = HalogenM (hoistFree go h)
  where
  go :: HalogenF s act ps o m ~> HalogenF s act ps o' m
  go = case _ of
    State fs -> State fs
    Subscribe fes a -> Subscribe fes a
    Unsubscribe sid a -> Unsubscribe sid a
    Lift q -> Lift q
    ChildQuery cq -> ChildQuery cq
    Raise o a -> Raise (f o) a
    Par p -> Par (over HalogenAp (hoistFreeAp (mapOutput f)) p)
    Fork fo -> Fork (FF.hoistFork (mapOutput f) fo)
    GetRef p k -> GetRef p k

hoist
  :: forall s act ps o m m'
   . Functor m'
  => (m ~> m')
  -> HalogenM' s act ps o m
  ~> HalogenM' s act ps o m'
hoist nat (HalogenM fa) = HalogenM (hoistFree go fa)
  where
  go :: HalogenF s act ps o m ~> HalogenF s act ps o m'
  go = case _ of
    State f -> State f
    Subscribe fes a -> Subscribe (ES.hoist nat <<< fes) a
    Unsubscribe sid a -> Unsubscribe sid a
    Lift q -> Lift (nat q)
    ChildQuery cq -> ChildQuery cq
    Raise o a -> Raise o a
    Par p -> Par (over HalogenAp (hoistFreeAp (hoist nat)) p)
    Fork fo -> Fork (FF.hoistFork (hoist nat) fo)
    GetRef p k -> GetRef p k
