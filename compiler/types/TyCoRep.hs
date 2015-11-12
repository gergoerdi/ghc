{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1998
\section[TyCoRep]{Type and Coercion - friends' interface}

Note [The Type-related module hierarchy]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Class
  CoAxiom
  TyCon    imports Class, CoAxiom
  TyCoRep  imports Class, CoAxiom, TyCon
  TysPrim  imports TyCoRep ( including mkTyConTy )
  Kind     imports TysPrim ( mainly for primitive kinds )
  Type     imports Kind
  Coercion imports Type
-}

-- We expose the relevant stuff from this module via the Type module
{-# OPTIONS_HADDOCK hide #-}
{-# LANGUAGE CPP, DeriveDataTypeable, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module TyCoRep (
        TyThing(..),
        Type(..),
        Binder(..),
        TyLit(..),
        KindOrType, Kind,
        PredType, ThetaType,      -- Synonyms
        VisibilityFlag(..),

        -- Coercions
        Coercion(..), LeftOrRight(..),
        UnivCoProvenance(..), CoercionHole(..),

        -- Functions over types
        mkTyConTy, mkTyVarTy, mkTyVarTys,
        mkFunTy,
        isLiftedTypeKind, isUnliftedTypeKind,
        isCoercionType, isLevityTy, isLevityVar,

        -- Functions over binders
        binderType, delBinderVar, isInvisibleBinder, isVisibleBinder,

        -- Functions over coercions
        pickLR,

        -- Pretty-printing
        pprType, pprParendType, pprTypeApp, pprTvBndr, pprTvBndrs,
        pprTyThing, pprTyThingCategory, pprSigmaType,
        pprTheta, pprForAll, pprForAllImplicit, pprUserForAll,
        pprThetaArrowTy, pprClassPred,
        pprKind, pprParendKind, pprTyLit, suppressImplicits,
        TyPrec(..), maybeParen, pprTcApp,
        pprPrefixApp, pprArrowChain, ppr_type,

        -- Free variables
        tyCoVarsOfType, tyCoVarsOfTypes,
        coVarsOfType, coVarsOfTypes,
        coVarsOfCo, coVarsOfCos,
        tyCoVarsOfCo, tyCoVarsOfCos,
        closeOverKinds,
        tyCoVarsOfTelescope,

        -- Substitutions
        TCvSubst(..), TvSubstEnv, CvSubstEnv,
        emptyTvSubstEnv, emptyCvSubstEnv, composeTCvSubstEnv, composeTCvSubst,
        emptyTCvSubst, mkEmptyTCvSubst, isEmptyTCvSubst, mkTCvSubst, getTvSubstEnv,
        getCvSubstEnv, getTCvInScope, isInScope, notElemTCvSubst,
        setTvSubstEnv, setCvSubstEnv, zapTCvSubst,
        extendTCvInScope, extendTCvInScopeList, extendTCvInScopeSet,
        extendTCvSubst, extendTCvSubstAndInScope, extendTCvSubstList,
        extendTCvSubstBinder,
        unionTCvSubst, zipTyEnv, zipCoEnv, mkTyCoInScopeSet,
        mkOpenTCvSubst, zipOpenTCvSubst, zipOpenTCvSubstCoVars,
        zipOpenTCvSubstBinders,
        mkTopTCvSubst, zipTopTCvSubst,

        substTelescope,
        substTyWith, substTyWithCoVars, substTysWith, substTysWithCoVars,
        substCoWith,
        substTy,
        substTyWithBinders,
        substTys, substTheta,
        lookupTyVar, substTyVarBndr,
        substCo, substCos, substCoVar, substCoVars, lookupCoVar,
        substCoVarBndr, cloneTyVarBndr,
        substTyVar, substTyVars,
        substForAllCoBndr,
        substTyVarBndrCallback, substForAllCoBndrCallback,
        substCoVarBndrCallback,

        -- * Tidying type related things up for printing
        tidyType,      tidyTypes,
        tidyOpenType,  tidyOpenTypes,
        tidyOpenKind,
        tidyTyCoVarBndr, tidyTyCoVarBndrs, tidyFreeTyCoVars,
        tidyOpenTyCoVar, tidyOpenTyCoVars,
        tidyTyVarOcc,
        tidyTopType,
        tidyKind,
        tidyCo, tidyCos
    ) where

#include "HsVersions.h"

import {-# SOURCE #-} DataCon( dataConTyCon )
import {-# SOURCE #-} Type( isPredTy, isCoercionTy, mkAppTy ) -- Transitively pulls in a LOT of stuff, better to break the loop
import {-# SOURCE #-} Coercion

-- friends:
import Var
import VarEnv
import VarSet
import Name hiding ( varName )
import BasicTypes
import TyCon
import Class
import CoAxiom
import ConLike

-- others
import PrelNames
import Binary
import Outputable
import DynFlags
import StaticFlags ( opt_PprStyle_Debug )
import FastString
import Pair
import Util

-- libraries
import qualified Data.Data as Data hiding ( TyCon )
import Data.List
import Data.IORef ( IORef )   -- for CoercionHole

{-
%************************************************************************
%*                                                                      *
\subsection{The data type}
%*                                                                      *
%************************************************************************
-}

-- | The key representation of types within the compiler

-- If you edit this type, you may need to update the GHC formalism
-- See Note [GHC Formalism] in coreSyn/CoreLint.hs
data Type
  -- See Note [Non-trivial definitional equality]
  = TyVarTy Var -- ^ Vanilla type or kind variable (*never* a coercion variable)

  | AppTy         -- See Note [AppTy rep]
        Type
        Type            -- ^ Type application to something other than a 'TyCon'. Parameters:
                        --
                        --  1) Function: must /not/ be a 'TyConApp',
                        --     must be another 'AppTy', or 'TyVarTy'
                        --
                        --  2) Argument type

  | TyConApp      -- See Note [AppTy rep]
        TyCon
        [KindOrType]    -- ^ Application of a 'TyCon', including newtypes /and/ synonyms.
                        -- Invariant: saturated applications of 'FunTyCon' must
                        -- use 'FunTy' and saturated synonyms must use their own
                        -- constructors. However, /unsaturated/ 'FunTyCon's
                        -- do appear as 'TyConApp's.
                        -- Parameters:
                        --
                        -- 1) Type constructor being applied to.
                        --
                        -- 2) Type arguments. Might not have enough type arguments
                        --    here to saturate the constructor.
                        --    Even type synonyms are not necessarily saturated;
                        --    for example unsaturated type synonyms
                        --    can appear as the right hand side of a type synonym.

  | ForAllTy
        Binder
        Type            -- ^ A Π type.
                        -- This includes arrow types, constructed with
                        -- @ForAllTy (Anon ...)@.

  | LitTy TyLit     -- ^ Type literals are similar to type constructors.

  | CastTy
        Type
        Coercion    -- ^ A kind cast. The coercion is always nominal.
                    -- INVARIANT: The cast is never refl.
                    -- INVARIANT: The cast is "pushed down" as far as it
                    -- can go. See Note [Pushing down casts]

  | CoercionTy
        Coercion    -- ^ Injection of a Coercion into a type
                    -- This should only ever be used in the RHS of an AppTy,
                    -- in the list of a TyConApp, or in a FunTy -- TODO (RAE): example

  deriving (Data.Data, Data.Typeable)


-- NOTE:  Other parts of the code assume that type literals do not contain
-- types or type variables.
data TyLit
  = NumTyLit Integer
  | StrTyLit FastString
  deriving (Eq, Ord, Data.Data, Data.Typeable)

-- | A 'Binder' represents an argument to a function. Binders can be dependent
-- ('Named') or nondependent ('Anon'). They may also be visible or not.
data Binder
  = Named TyVar VisibilityFlag
  | Anon Type   -- visibility is determined by the type (Constraint vs. *)
    deriving (Data.Typeable, Data.Data)

-- | TODO (RAE): Add comment
data VisibilityFlag = Visible | Invisible
  deriving (Eq, Data.Typeable, Data.Data)

instance Binary VisibilityFlag where
  put_ bh Visible   = putByte bh 0
  put_ bh Invisible = putByte bh 1

  get bh = do
    h <- getByte bh
    case h of
      0 -> return Visible
      _ -> return Invisible

type KindOrType = Type -- See Note [Arguments to type constructors]

-- | The key type representing kinds in the compiler.
type Kind = Type

{-
Note [The kind invariant]
~~~~~~~~~~~~~~~~~~~~~~~~~
The kinds
   #          UnliftedTypeKind
   OpenKind   super-kind of *, #

can never appear under an arrow or type constructor in a kind; they
can only be at the top level of a kind.  It follows that primitive TyCons,
which have a naughty pseudo-kind
   State# :: * -> #
must always be saturated, so that we can never get a type whose kind
has a UnliftedTypeKind or ArgTypeKind underneath an arrow.

Nor can we abstract over a type variable with any of these kinds.

    k :: = kk | # | ArgKind | (#) | OpenKind
    kk :: = * | kk -> kk | T kk1 ... kkn

So a type variable can only be abstracted kk.

Note [Arguments to type constructors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Because of kind polymorphism, in addition to type application we now
have kind instantiation. We reuse the same notations to do so.

For example:

  Just (* -> *) Maybe
  Right * Nat Zero

are represented by:

  TyConApp (PromotedDataCon Just) [* -> *, Maybe]
  TyConApp (PromotedDataCon Right) [*, Nat, (PromotedDataCon Zero)]

Important note: Nat is used as a *kind* and not as a type. This can be
confusing, since type-level Nat and kind-level Nat are identical. We
use the kind of (PromotedDataCon Right) to know if its arguments are
kinds or types.

This kind instantiation only happens in TyConApp currently.

Note [Type abstraction over coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Types can be abstracted over coercions, and thus in many places where we used
to consider only tyvars, we must now also consider the possibility of covars.
But where, really, can these covars appear? In precisely these locations:
  - the kind of a promoted GADT data constructor
  - the existential variables of a data constructor (TODO (RAE): Really?? ~ vs ~#)
  - the type of the constructor Eq# (in type (~))
  - the quantified vars for an axiom branch
  - the type of an id

That's it. In particular, coercion variables MAY NOT appear in the quantified
tyvars of a TyCon (other than a promoted data constructor), of a class, of a
type synonym (regular or family).

Note [Pushing down casts]
~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have (a :: k1 -> *), (b :: k1), and (co :: * ~ q).
The type (a b |> co) is `eqType` to ((a |> co') b), where
co' = (->) <k1> co. Thus, to make this visible to functions
that inspect types, we always push down coercions, preferring
the second form. Note that this also applies to TyConApps!

Note [Non-trivial definitional equality]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Is Int |> <*> the same as Int? YES! In order to reduce headaches,
we decide that any reflexive casts in types are just ignored. More
generally, the `eqType` function, which defines Core's type equality
relation, ignores casts and coercion arguments, as long as the
two types have the same kind. This allows us to be a little sloppier
in keeping track of coercions, which is a good thing. It also means
that eqType does not depend on eqCoercion, which is also a good thing.

-------------------------------------
                Note [PredTy]
-}

-- | A type of the form @p@ of kind @Constraint@ represents a value whose type is
-- the Haskell predicate @p@, where a predicate is what occurs before
-- the @=>@ in a Haskell type.
--
-- We use 'PredType' as documentation to mark those types that we guarantee to have
-- this kind.
--
-- It can be expanded into its representation, but:
--
-- * The type checker must treat it as opaque
--
-- * The rest of the compiler treats it as transparent
--
-- Consider these examples:
--
-- > f :: (Eq a) => a -> Int
-- > g :: (?x :: Int -> Int) => a -> Int
-- > h :: (r\l) => {r} => {l::Int | r}
--
-- Here the @Eq a@ and @?x :: Int -> Int@ and @r\l@ are all called \"predicates\"
type PredType = Type

-- | A collection of 'PredType's
type ThetaType = [PredType]

{-
(We don't support TREX records yet, but the setup is designed
to expand to allow them.)

A Haskell qualified type, such as that for f,g,h above, is
represented using
        * a FunTy for the double arrow
        * with a type of kind Constraint as the function argument

The predicate really does turn into a real extra argument to the
function.  If the argument has type (p :: Constraint) then the predicate p is
represented by evidence of type p.

%************************************************************************
%*                                                                      *
            Simple constructors
%*                                                                      *
%************************************************************************

These functions are here so that they can be used by TysPrim,
which in turn is imported by Type
-}

-- named with "Only" to prevent naive use of mkTyVarTy
mkTyVarTy  :: TyVar   -> Type
mkTyVarTy v = ASSERT2( isTyVar v, ppr v <+> dcolon <+> ppr (tyVarKind v) )
                  TyVarTy v

mkTyVarTys :: [TyVar] -> [Type]
mkTyVarTys = map mkTyVarTy -- a common use of mkTyVarTy

infixr 3 `mkFunTy`      -- Associates to the right
-- | Make an arrow type
mkFunTy :: Type -> Type -> Type
mkFunTy arg res
  = ForAllTy (Anon arg) res

-- | Does this type classify a core Coercion?
isCoercionType :: Type -> Bool
isCoercionType (TyConApp tc tys)
  | (tc `hasKey` eqPrimTyConKey) || (tc `hasKey` eqReprPrimTyConKey)
  , length tys == 4
  = True
isCoercionType _ = False

binderType :: Binder -> Type
binderType (Named v _) = varType v
binderType (Anon ty)   = ty

-- | Remove the binder's variable from the set, if the binder has
-- a variable.
delBinderVar :: VarSet -> Binder -> VarSet
delBinderVar vars (Named tv _) = vars `delVarSet` tv
delBinderVar vars (Anon {})    = vars

-- | Does this binder bind an invisible argument?
isInvisibleBinder :: Binder -> Bool
isInvisibleBinder (Named _ Invisible) = True
isInvisibleBinder _                   = False
  -- TODO (RAE): Shouldn't this check the kind of an Anon?
  -- If this changes, change splitForAllTysInvisible as well

-- | Does this binder bind a visible argument?
isVisibleBinder :: Binder -> Bool
isVisibleBinder = not . isInvisibleBinder

-- | Create the plain type constructor type which has been applied to no type arguments at all.
mkTyConTy :: TyCon -> Type
mkTyConTy tycon = TyConApp tycon []

{-
Some basic functions, put here to break loops eg with the pretty printer
-}

isLiftedTypeKind :: Kind -> Bool
isLiftedTypeKind (TyConApp tc []) = tc `hasKey` liftedTypeKindTyConKey
isLiftedTypeKind (TyConApp tc [TyConApp lev []])
  = tc `hasKey` tYPETyConKey && lev `hasKey` liftedDataConKey
isLiftedTypeKind _                = False

isUnliftedTypeKind :: Kind -> Bool
isUnliftedTypeKind (TyConApp tc []) = tc `hasKey` unliftedTypeKindTyConKey
isUnliftedTypeKind (TyConApp tc [TyConApp lev []])
  = tc `hasKey` tYPETyConKey && lev `hasKey` unliftedDataConKey
isUnliftedTypeKind _ = False

-- | Is this the type 'Levity'?
isLevityTy :: Type -> Bool
isLevityTy (TyConApp tc []) = tc `hasKey` levityTyConKey
isLevityTy _                = False

-- | Is a tyvar of type 'Levity'?
isLevityVar :: TyVar -> Bool
isLevityVar = isLevityTy . tyVarKind

{-
%************************************************************************
%*                                                                      *
            Coercions
%*                                                                      *
%************************************************************************
-}

-- | A 'Coercion' is concrete evidence of the equality/convertibility
-- of two types.

-- If you edit this type, you may need to update the GHC formalism
-- See Note [GHC Formalism] in coreSyn/CoreLint.hs
data Coercion
  -- Each constructor has a "role signature", indicating the way roles are
  -- propagated through coercions. P, N, and R stand for coercions of the
  -- given role. e stands for a coercion of a specific unknown role (think
  -- "role polymorphism"). "e" stands for an explicit role parameter
  -- indicating role e. _ stands for a parameter that is not a Role or
  -- Coercion.

  -- These ones mirror the shape of types
  = -- Refl :: "e" -> _ -> e
    Refl Role Type  -- See Note [Refl invariant]
          -- Invariant: applications of (Refl T) to a bunch of identity coercions
          --            always show up as Refl.
          -- For example  (Refl T) (Refl a) (Refl b) shows up as (Refl (T a b)).

          -- Applications of (Refl T) to some coercions, at least one of
          -- which is NOT the identity, show up as TyConAppCo.
          -- (They may not be fully saturated however.)
          -- ConAppCo coercions (like all coercions other than Refl)
          -- are NEVER the identity.

          -- Use (Refl Representational _), not (SubCo (Refl Nominal _))

  -- These ones simply lift the correspondingly-named
  -- Type constructors into Coercions

  -- TyConAppCo :: "e" -> _ -> ?? -> e
  -- See Note [TyConAppCo roles]
  | TyConAppCo Role TyCon [Coercion]    -- lift TyConApp
               -- The TyCon is never a synonym;
               -- we expand synonyms eagerly
               -- But it can be a type function

  | AppCo Coercion Coercion             -- lift AppTy
          -- AppCo :: e -> N -> e

  -- See Note [Forall coercions]
  | ForAllCo TyVar Coercion Coercion
         -- ForAllCo :: _ -> N -> e -> e

  -- These are special
  | CoVarCo CoVar      -- :: _ -> (N or R)
                       -- result role depends on the tycon of the variable's type

    -- AxiomInstCo :: e -> _ -> [N] -> e
  | AxiomInstCo (CoAxiom Branched) BranchIndex [Coercion]
     -- See also [CoAxiom index]
     -- The coercion arguments always *precisely* saturate
     -- arity of (that branch of) the CoAxiom. If there are
     -- any left over, we use AppCo.
     -- See [Coercion axioms applied to coercions]

  | UnivCo UnivCoProvenance Role Type Type
      -- :: _ -> "e" -> _ -> _ -> e

  | SymCo Coercion             -- :: e -> e
  | TransCo Coercion Coercion  -- :: e -> e -> e

    -- The number coercions should match exactly the expectations
    -- of the CoAxiomRule (i.e., the rule is fully saturated).
  | AxiomRuleCo CoAxiomRule [Coercion]

  | NthCo  Int         Coercion     -- Zero-indexed; decomposes (T t0 ... tn)
    -- :: _ -> e -> ?? (inverse of TyConAppCo, see Note [TyConAppCo roles])
    -- Using NthCo on a ForAllCo gives an N coercion always
    -- See Note [NthCo and newtypes]

  | LRCo   LeftOrRight Coercion     -- Decomposes (t_left t_right)
    -- :: _ -> N -> N
  | InstCo Coercion Coercion
    -- :: e -> N -> e
    -- See Note [InstCo roles]

  -- Coherence applies a coercion to the left-hand type of another coercion
  -- See Note [Coherence]
  | CoherenceCo Coercion Coercion
     -- :: e -> N -> e

  -- Extract a kind coercion from a (heterogeneous) type coercion
  -- NB: all kind coercions are Nominal
  | KindCo Coercion
     -- :: e -> N

  | SubCo Coercion                  -- Turns a ~N into a ~R
    -- :: N -> R

  deriving (Data.Data, Data.Typeable)

-- If you edit this type, you may need to update the GHC formalism
-- See Note [GHC Formalism] in coreSyn/CoreLint.hs
data LeftOrRight = CLeft | CRight
                 deriving( Eq, Data.Data, Data.Typeable )

instance Binary LeftOrRight where
   put_ bh CLeft  = putByte bh 0
   put_ bh CRight = putByte bh 1

   get bh = do { h <- getByte bh
               ; case h of
                   0 -> return CLeft
                   _ -> return CRight }

pickLR :: LeftOrRight -> (a,a) -> a
pickLR CLeft  (l,_) = l
pickLR CRight (_,r) = r

{-
%************************************************************************
%*                                                                      *
     UnivCo Provenance
%*                                                                      *
%************************************************************************

Note [Coercion holes]
~~~~~~~~~~~~~~~~~~~~~
During typechecking, we emit constraints for kind coercions, to be used
to cast a type's kind. These coercions then must be used in types. Because
they might appear in a top-level type, there is no place to bind these
(unlifted) coercions in the usual way. So, instead of creating a coercion
variable and then solving for the variable, we use a coercion hole, which
is just an unnamed mutable cell. During type-checking, the holes are filled
in. The Unique carried with a coercion hole is used solely for debugging.
Coercion holes can be compared for equality only like other coercions:
only by looking at the types coerced.

Holes should never appear in Core. If, one day, we use type-level information
to separate out forms that can appear during type-checking vs forms that can
appear in core proper, holes in Core will be ruled out. (This is quite like
the fact that Type can, technically, store TcTyVars but never do.)

Note that we don't use holes for other evidence because other evidence wants
to be shared. But coercions are entirely erased, so there's little benefit
to sharing.

Note [ProofIrrelProv]
~~~~~~~~~~~~~~~~~~~~~
A ProofIreelProv is a coercion between coercions. For example:

  data G a where
    MkG :: G Bool

In core, we get

  G :: * -> *
  MkG :: forall (a :: *). (a ~ Bool) -> G a

Now, consider 'MkG -- that is, MkG used in a type -- and suppose we want
a proof that ('MkG co1 a1) ~ ('MkG co2 a2). This will have to be

  TyConAppCo Nominal MkG [co3, co4]
  where
    co3 :: co1 ~ co2
    co4 :: a1 ~ a2

Note that
  co1 :: a1 ~ Bool
  co2 :: a2 ~ Bool

Here,
  co3 = UnivCo (ProofIrrelProv co5) Nominal (CoercionTy co1) (CoercionTy co2)
  where
    co5 :: (a1 ~ Bool) ~ (a2 ~ Bool)
    co5 = TyConAppCo Nominal (~) [<*>, <*>, co4, <Bool>]

-}

-- | For simplicity, we have just one UnivCo that represents a coercion from
-- some type to some other type, with (in general) no restrictions on the
-- type. To make better sense of these, we tag a UnivCo with a
-- UnivCoProvenance. This provenance is rarely consulted and is more
-- for debugging info than anything else.
-- An important exception to this rule is that we also use a UnivCo
-- for coercion holes. See Note [Coercion holes].
data UnivCoProvenance
  = UnsafeCoerceProv   -- ^ From @unsafeCoerce#@. These are unsound.
  | PhantomProv Coercion -- ^ From the need to create a phantom coercion;
                         --   the UnivCo must be Phantom. The Coercion stored is
                         --   the (nominal) kind coercion between the types
  | ProofIrrelProv Coercion  -- ^ From the fact that any two coercions are
                             --   considered equivalent. See Note [ProofIrrelProv]
  | PluginProv String  -- ^ From a plugin, which asserts that this coercion
                       --   is sound. The string is for the use of the plugin.
  | HoleProv CoercionHole  -- ^ See Note [Coercion holes]
  deriving (Data.Data, Data.Typeable)

instance Outputable UnivCoProvenance where
  ppr UnsafeCoerceProv   = text "(unsafeCoerce#)"
  ppr (PhantomProv _)    = text "(phantom)"
  ppr (ProofIrrelProv _) = text "(proof irrel.)"
  ppr (PluginProv str)   = parens (text "plugin" <+> brackets (text str))
  ppr (HoleProv hole)    = parens (text "hole" <> ppr hole)

-- | A coercion to be filled in by the type-checker. See Note [Coercion holes]
data CoercionHole
  = CoercionHole Unique   -- ^ used only for debugging
                 (IORef (Maybe Coercion))
  deriving (Data.Typeable)

instance Data.Data CoercionHole where
  -- don't traverse?
  toConstr _   = abstractConstr "CoercionHole"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "CoercionHole"

instance Outputable CoercionHole where
  ppr (CoercionHole u _) = braces (ppr u)

{-
Note [Refl invariant]
~~~~~~~~~~~~~~~~~~~~~
Invariant 1:

Coercions have the following invariant
     Refl is always lifted as far as possible.

You might think that a consequencs is:
     Every identity coercions has Refl at the root

But that's not quite true because of coercion variables.  Consider
     g         where g :: Int~Int
     Left h    where h :: Maybe Int ~ Maybe Int
etc.  So the consequence is only true of coercions that
have no coercion variables.

Invariant 2:

All coercions other than Refl are guaranteed to coerce between two
*distinct* types.

Note [Coercion axioms applied to coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The reason coercion axioms can be applied to coercions and not just
types is to allow for better optimization.  There are some cases where
we need to be able to "push transitivity inside" an axiom in order to
expose further opportunities for optimization.

For example, suppose we have

  C a : t[a] ~ F a
  g   : b ~ c

and we want to optimize

  sym (C b) ; t[g] ; C c

which has the kind

  F b ~ F c

(stopping through t[b] and t[c] along the way).

We'd like to optimize this to just F g -- but how?  The key is
that we need to allow axioms to be instantiated by *coercions*,
not just by types.  Then we can (in certain cases) push
transitivity inside the axiom instantiations, and then react
opposite-polarity instantiations of the same axiom.  In this
case, e.g., we match t[g] against the LHS of (C c)'s kind, to
obtain the substitution  a |-> g  (note this operation is sort
of the dual of lifting!) and hence end up with

  C g : t[b] ~ F c

which indeed has the same kind as  t[g] ; C c.

Now we have

  sym (C b) ; C g

which can be optimized to F g.

Note [CoAxiom index]
~~~~~~~~~~~~~~~~~~~~
A CoAxiom has 1 or more branches. Each branch has contains a list
of the free type variables in that branch, the LHS type patterns,
and the RHS type for that branch. When we apply an axiom to a list
of coercions, we must choose which branch of the axiom we wish to
use, as the different branches may have different numbers of free
type variables. (The number of type patterns is always the same
among branches, but that doesn't quite concern us here.)

The Int in the AxiomInstCo constructor is the 0-indexed number
of the chosen branch.

Note [Forall coercions]
~~~~~~~~~~~~~~~~~~~~~~~
Constructing coercions between forall-types can be a bit tricky,
because the kinds of the bound tyvars can be different.

The typing rule is:


  kind_co : k1 ~ k2
  tv1:k1 |- co : t1 ~ t2
  -------------------------------------------------------------------
  ForAllCo tv1 kind_co co : all tv1:k1. t1  ~
                            all tv1:k2. (t2[tv1 |-> tv1 |> sym kind_co])

First, the TyVar stored in a ForAllCo is really an optimisation: this field
should be a Name, as its kind is redundant. Thinking of the field as a Name
is helpful in understanding what a ForAllCo means.

The idea is that kind_co gives the two kinds of the tyvar. See how, in the
conclusion, tv1 is assigned kind k1 on the left but kind k2 on the right.

Of course, a type variable can't have different kinds at the same time. So,
we arbitrarily prefer the first kind when using tv1 in the inner coercion
co, which shows that t1 equals t2.

The last wrinkle is that we need to fix the kinds in the conclusion. In
t2, tv1 is assumed to have kind k1, but it has kind k2 in the conclusion of
the rule. So we do a kind-fixing substitution, replacing (tv1:k1) with
(tv1:k2) |> sym kind_co. This substitution is slightly bizarre, because it
mentions the same name with different kinds, but it *is* well-kinded, noting
that `(tv1:k2) |> sym kind_co` has kind k1.

This all really would work storing just a Name in the ForAllCo. But we can't
add Names to, e.g., VarSets, and there generally is just an impedence mismatch
in a bunch of places. So we use tv1. When we need tv2, we can use
setTyVarKind.

Note [Coherence]
~~~~~~~~~~~~~~~~
The Coherence typing rule is thus:

  g1 : s ~ t    s : k1    g2 : k1 ~ k2
  ------------------------------------
  CoherenceCo g1 g2 : (s |> g2) ~ t

While this look (and is) unsymmetric, a combination of other coercion
combinators can make the symmetric version.

For role information, see Note [Roles and kind coercions].

Note [Predicate coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have
   g :: a~b
How can we coerce between types
   ([c]~a) => [a] -> c
and
   ([c]~b) => [b] -> c
where the equality predicate *itself* differs?

Answer: we simply treat (~) as an ordinary type constructor, so these
types really look like

   ((~) [c] a) -> [a] -> c
   ((~) [c] b) -> [b] -> c

So the coercion between the two is obviously

   ((~) [c] g) -> [g] -> c

Another way to see this to say that we simply collapse predicates to
their representation type (see Type.coreView and Type.predTypeRep).

This collapse is done by mkPredCo; there is no PredCo constructor
in Coercion.  This is important because we need Nth to work on
predicates too:
    Nth 1 ((~) [c] g) = g
See Simplify.simplCoercionF, which generates such selections.

Note [Roles]
~~~~~~~~~~~~
Roles are a solution to the GeneralizedNewtypeDeriving problem, articulated
in Trac #1496. The full story is in docs/core-spec/core-spec.pdf. Also, see
http://ghc.haskell.org/trac/ghc/wiki/RolesImplementation

Here is one way to phrase the problem:

Given:
newtype Age = MkAge Int
type family F x
type instance F Age = Bool
type instance F Int = Char

This compiles down to:
axAge :: Age ~ Int
axF1 :: F Age ~ Bool
axF2 :: F Int ~ Char

Then, we can make:
(sym (axF1) ; F axAge ; axF2) :: Bool ~ Char

Yikes!

The solution is _roles_, as articulated in "Generative Type Abstraction and
Type-level Computation" (POPL 2010), available at
http://www.seas.upenn.edu/~sweirich/papers/popl163af-weirich.pdf

The specification for roles has evolved somewhat since that paper. For the
current full details, see the documentation in docs/core-spec. Here are some
highlights.

We label every equality with a notion of type equivalence, of which there are
three options: Nominal, Representational, and Phantom. A ground type is
nominally equivalent only with itself. A newtype (which is considered a ground
type in Haskell) is representationally equivalent to its representation.
Anything is "phantomly" equivalent to anything else. We use "N", "R", and "P"
to denote the equivalences.

The axioms above would be:
axAge :: Age ~R Int
axF1 :: F Age ~N Bool
axF2 :: F Age ~N Char

Then, because transitivity applies only to coercions proving the same notion
of equivalence, the above construction is impossible.

However, there is still an escape hatch: we know that any two types that are
nominally equivalent are representationally equivalent as well. This is what
the form SubCo proves -- it "demotes" a nominal equivalence into a
representational equivalence. So, it would seem the following is possible:

sub (sym axF1) ; F axAge ; sub axF2 :: Bool ~R Char   -- WRONG

What saves us here is that the arguments to a type function F, lifted into a
coercion, *must* prove nominal equivalence. So, (F axAge) is ill-formed, and
we are safe.

Roles are attached to parameters to TyCons. When lifting a TyCon into a
coercion (through TyConAppCo), we need to ensure that the arguments to the
TyCon respect their roles. For example:

data T a b = MkT a (F b)

If we know that a1 ~R a2, then we know (T a1 b) ~R (T a2 b). But, if we know
that b1 ~R b2, we know nothing about (T a b1) and (T a b2)! This is because
the type function F branches on b's *name*, not representation. So, we say
that 'a' has role Representational and 'b' has role Nominal. The third role,
Phantom, is for parameters not used in the type's definition. Given the
following definition

data Q a = MkQ Int

the Phantom role allows us to say that (Q Bool) ~R (Q Char), because we
can construct the coercion Bool ~P Char (using UnivCo).

See the paper cited above for more examples and information.

Note [TyConAppCo roles]
~~~~~~~~~~~~~~~~~~~~~~~
The TyConAppCo constructor has a role parameter, indicating the role at
which the coercion proves equality. The choice of this parameter affects
the required roles of the arguments of the TyConAppCo. To help explain
it, assume the following definition:

  type instance F Int = Bool   -- Axiom axF : F Int ~N Bool
  newtype Age = MkAge Int      -- Axiom axAge : Age ~R Int
  data Foo a = MkFoo a         -- Role on Foo's parameter is Representational

TyConAppCo Nominal Foo axF : Foo (F Int) ~N Foo Bool
  For (TyConAppCo Nominal) all arguments must have role Nominal. Why?
  So that Foo Age ~N Foo Int does *not* hold.

TyConAppCo Representational Foo (SubCo axF) : Foo (F Int) ~R Foo Bool
TyConAppCo Representational Foo axAge       : Foo Age     ~R Foo Int
  For (TyConAppCo Representational), all arguments must have the roles
  corresponding to the result of tyConRoles on the TyCon. This is the
  whole point of having roles on the TyCon to begin with. So, we can
  have Foo Age ~R Foo Int, if Foo's parameter has role R.

  If a Representational TyConAppCo is over-saturated (which is otherwise fine),
  the spill-over arguments must all be at Nominal. This corresponds to the
  behavior for AppCo.

TyConAppCo Phantom Foo (UnivCo Phantom Int Bool) : Foo Int ~P Foo Bool
  All arguments must have role Phantom. This one isn't strictly
  necessary for soundness, but this choice removes ambiguity.

The rules here dictate the roles of the parameters to mkTyConAppCo
(should be checked by Lint).

Note [NthCo and newtypes]
~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have

  newtype N a = MkN Int
  type role N representational

This yields axiom

  NTCo:N :: forall a. N a ~R Int

We can then build

  co :: forall a b. N a ~R N b
  co = NTCo:N a ; sym (NTCo:N b)

for any `a` and `b`. Because of the role annotation on N, if we use
NthCo, we'll get out a representational coercion. That is:

  NthCo 0 co :: forall a b. a ~R b

Yikes! Clearly, this is terrible. The solution is simple: forbid
NthCo to be used on newtypes if the internal coercion is representational.

This is not just some corner case discovered by a segfault somewhere;
it was discovered in the proof of soundness of roles and described
in the "Safe Coercions" paper (ICFP '14).

Note [InstCo roles]
~~~~~~~~~~~~~~~~~~~
Here is (essentially) the typing rule for InstCo:

g :: (forall a. t1) ~r (forall a. t2)
w :: s1 ~N s2
------------------------------- InstCo
InstCo g w :: (t1 [a |-> s1]) ~r (t2 [a |-> s2])

Note that the Coercion w *must* be nominal. This is necessary
because the variable a might be used in a "nominal position"
(that is, a place where role inference would require a nominal
role) in t1 or t2. If we allowed w to be representational, we
could get bogus equalities.

A more nuanced treatment might be able to relax this condition
somewhat, by checking if t1 and/or t2 use their bound variables
in nominal ways. If not, having w be representational is OK.

%************************************************************************
%*                                                                      *
                 Free variables of types and coercions
%*                                                                      *
%************************************************************************
-}

tyCoVarsOfType :: Type -> TyCoVarSet
-- ^ NB: for type synonyms tyCoVarsOfType does /not/ expand the synonym
-- tyVarsOfType returns free variables of a type, including kind variables.
tyCoVarsOfType (TyVarTy v)         = unitVarSet v `unionVarSet` tyCoVarsOfType (tyVarKind v)
tyCoVarsOfType (TyConApp _ tys)    = tyCoVarsOfTypes tys
tyCoVarsOfType (LitTy {})          = emptyVarSet
tyCoVarsOfType (AppTy fun arg)     = tyCoVarsOfType fun `unionVarSet` tyCoVarsOfType arg
tyCoVarsOfType (ForAllTy bndr ty)
  = tyCoVarsOfType ty `delBinderVar` bndr
    `unionVarSet` tyCoVarsOfType (binderType bndr)
tyCoVarsOfType (CastTy ty co)      = tyCoVarsOfType ty `unionVarSet` tyCoVarsOfCo co
tyCoVarsOfType (CoercionTy co)     = tyCoVarsOfCo co

tyCoVarsOfTypes :: [Type] -> TyCoVarSet
tyCoVarsOfTypes tys = mapUnionVarSet tyCoVarsOfType tys

tyCoVarsOfCo :: Coercion -> TyCoVarSet
-- Extracts type and coercion variables from a coercion
tyCoVarsOfCo (Refl _ ty)         = tyCoVarsOfType ty
tyCoVarsOfCo (TyConAppCo _ _ args) = tyCoVarsOfCos args
tyCoVarsOfCo (AppCo co arg)      = tyCoVarsOfCo co `unionVarSet` tyCoVarsOfCo arg
tyCoVarsOfCo (ForAllCo tv kind_co co)
  = tyCoVarsOfCo co `delVarSet` tv `unionVarSet` tyCoVarsOfCo kind_co
tyCoVarsOfCo (CoVarCo v)         = unitVarSet v `unionVarSet` tyCoVarsOfType (varType v)
tyCoVarsOfCo (AxiomInstCo _ _ cos) = tyCoVarsOfCos cos
tyCoVarsOfCo (UnivCo p _ t1 t2)  = tyCoVarsOfProv p `unionVarSet` tyCoVarsOfType t1 `unionVarSet` tyCoVarsOfType t2
tyCoVarsOfCo (SymCo co)          = tyCoVarsOfCo co
tyCoVarsOfCo (TransCo co1 co2)   = tyCoVarsOfCo co1 `unionVarSet` tyCoVarsOfCo co2
tyCoVarsOfCo (NthCo _ co)        = tyCoVarsOfCo co
tyCoVarsOfCo (LRCo _ co)         = tyCoVarsOfCo co
tyCoVarsOfCo (InstCo co arg)     = tyCoVarsOfCo co `unionVarSet` tyCoVarsOfCo arg
tyCoVarsOfCo (CoherenceCo c1 c2) = tyCoVarsOfCo c1 `unionVarSet` tyCoVarsOfCo c2
tyCoVarsOfCo (KindCo co)         = tyCoVarsOfCo co
tyCoVarsOfCo (SubCo co)          = tyCoVarsOfCo co
tyCoVarsOfCo (AxiomRuleCo _ cs)  = tyCoVarsOfCos cs

tyCoVarsOfProv :: UnivCoProvenance -> TyCoVarSet
tyCoVarsOfProv UnsafeCoerceProv    = emptyVarSet
tyCoVarsOfProv (PhantomProv co)    = tyCoVarsOfCo co
tyCoVarsOfProv (ProofIrrelProv co) = tyCoVarsOfCo co
tyCoVarsOfProv (PluginProv _)      = emptyVarSet
tyCoVarsOfProv (HoleProv _)        = emptyVarSet

tyCoVarsOfCos :: [Coercion] -> TyCoVarSet
tyCoVarsOfCos cos = mapUnionVarSet tyCoVarsOfCo cos

coVarsOfType :: Type -> CoVarSet
coVarsOfType (TyVarTy v)         = coVarsOfType (tyVarKind v)
coVarsOfType (TyConApp _ tys)    = coVarsOfTypes tys
coVarsOfType (LitTy {})          = emptyVarSet
coVarsOfType (AppTy fun arg)     = coVarsOfType fun `unionVarSet` coVarsOfType arg
coVarsOfType (ForAllTy bndr ty)
  = coVarsOfType ty `delBinderVar` bndr
    `unionVarSet` coVarsOfType (binderType bndr)
coVarsOfType (CastTy ty co)      = coVarsOfType ty `unionVarSet` coVarsOfCo co
coVarsOfType (CoercionTy co)     = coVarsOfCo co

coVarsOfTypes :: [Type] -> TyCoVarSet
coVarsOfTypes tys = mapUnionVarSet coVarsOfType tys

coVarsOfCo :: Coercion -> CoVarSet
-- Extract *coercion* variables only.  Tiresome to repeat the code, but easy.
coVarsOfCo (Refl _ ty)         = coVarsOfType ty
coVarsOfCo (TyConAppCo _ _ args) = coVarsOfCos args
coVarsOfCo (AppCo co arg)      = coVarsOfCo co `unionVarSet` coVarsOfCo arg
coVarsOfCo (ForAllCo tv kind_co co)
  = coVarsOfCo co `delVarSet` tv `unionVarSet` coVarsOfCo kind_co
coVarsOfCo (CoVarCo v)         = unitVarSet v `unionVarSet` coVarsOfType (varType v)
coVarsOfCo (AxiomInstCo _ _ args) = coVarsOfCos args
coVarsOfCo (UnivCo p _ t1 t2)  = coVarsOfProv p `unionVarSet` coVarsOfTypes [t1, t2]
coVarsOfCo (SymCo co)          = coVarsOfCo co
coVarsOfCo (TransCo co1 co2)   = coVarsOfCo co1 `unionVarSet` coVarsOfCo co2
coVarsOfCo (NthCo _ co)        = coVarsOfCo co
coVarsOfCo (LRCo _ co)         = coVarsOfCo co
coVarsOfCo (InstCo co arg)     = coVarsOfCo co `unionVarSet` coVarsOfCo arg
coVarsOfCo (CoherenceCo c1 c2) = coVarsOfCos [c1, c2]
coVarsOfCo (KindCo co)         = coVarsOfCo co
coVarsOfCo (SubCo co)          = coVarsOfCo co
coVarsOfCo (AxiomRuleCo _ cs)  = coVarsOfCos cs

coVarsOfProv :: UnivCoProvenance -> CoVarSet
coVarsOfProv UnsafeCoerceProv    = emptyVarSet
coVarsOfProv (PhantomProv co)    = coVarsOfCo co
coVarsOfProv (ProofIrrelProv co) = coVarsOfCo co
coVarsOfProv (PluginProv _)      = emptyVarSet
coVarsOfProv (HoleProv _)        = emptyVarSet

coVarsOfCos :: [Coercion] -> CoVarSet
coVarsOfCos cos = mapUnionVarSet coVarsOfCo cos

closeOverKinds :: TyCoVarSet -> TyCoVarSet
-- Add the kind variables free in the kinds
-- of the tyvars in the given set
closeOverKinds tvs
  = foldVarSet (\tv ktvs -> closeOverKinds (tyCoVarsOfType (tyVarKind tv))
                            `unionVarSet` ktvs) tvs tvs

-- | Gets the free vars of a telescope, scoped over a given free var set.
tyCoVarsOfTelescope :: [Var] -> TyCoVarSet -> TyCoVarSet
tyCoVarsOfTelescope [] fvs = fvs
tyCoVarsOfTelescope (v:vs) fvs = tyCoVarsOfTelescope vs fvs
                                 `delVarSet` v
                                 `unionVarSet` tyCoVarsOfType (varType v)
{-
%************************************************************************
%*                                                                      *
                        TyThing
%*                                                                      *
%************************************************************************

Despite the fact that DataCon has to be imported via a hi-boot route,
this module seems the right place for TyThing, because it's needed for
funTyCon and all the types in TysPrim.

Note [ATyCon for classes]
~~~~~~~~~~~~~~~~~~~~~~~~~
Both classes and type constructors are represented in the type environment
as ATyCon.  You can tell the difference, and get to the class, with
   isClassTyCon :: TyCon -> Bool
   tyConClass_maybe :: TyCon -> Maybe Class
The Class and its associated TyCon have the same Name.
-}

-- | A global typecheckable-thing, essentially anything that has a name.
-- Not to be confused with a 'TcTyThing', which is also a typecheckable
-- thing but in the *local* context.  See 'TcEnv' for how to retrieve
-- a 'TyThing' given a 'Name'.
data TyThing
  = AnId     Id
  | AConLike ConLike
  | ATyCon   TyCon       -- TyCons and classes; see Note [ATyCon for classes]
  | ACoAxiom (CoAxiom Branched)
  deriving (Eq, Ord)

instance Outputable TyThing where
  ppr = pprTyThing

pprTyThing :: TyThing -> SDoc
pprTyThing thing = pprTyThingCategory thing <+> quotes (ppr (getName thing))

pprTyThingCategory :: TyThing -> SDoc
pprTyThingCategory (ATyCon tc)
  | isClassTyCon tc = ptext (sLit "Class")
  | otherwise       = ptext (sLit "Type constructor")
pprTyThingCategory (ACoAxiom _) = ptext (sLit "Coercion axiom")
pprTyThingCategory (AnId   _)   = ptext (sLit "Identifier")
pprTyThingCategory (AConLike (RealDataCon _)) = ptext (sLit "Data constructor")
pprTyThingCategory (AConLike (PatSynCon _))  = ptext (sLit "Pattern synonym")


instance NamedThing TyThing where       -- Can't put this with the type
  getName (AnId id)     = getName id    -- decl, because the DataCon instance
  getName (ATyCon tc)   = getName tc    -- isn't visible there
  getName (ACoAxiom cc) = getName cc
  getName (AConLike cl) = getName cl

{-
%************************************************************************
%*                                                                      *
                        Substitutions
      Data type defined here to avoid unnecessary mutual recursion
%*                                                                      *
%************************************************************************
-}

-- | Type & coercion substitution
--
-- #tcvsubst_invariant#
-- The following invariants must hold of a 'TCvSubst':
--
-- 1. The in-scope set is needed /only/ to
-- guide the generation of fresh uniques
--
-- 2. In particular, the /kind/ of the type variables in
-- the in-scope set is not relevant
--
-- 3. The substitution is only applied ONCE! This is because
-- in general such application will not reach a fixed point.
data TCvSubst
  = TCvSubst InScopeSet -- The in-scope type and kind variables
             TvSubstEnv -- Substitutes both type and kind variables
             CvSubstEnv -- Substitutes coercion variables
        -- See Note [Apply Once]
        -- and Note [Extending the TvSubstEnv]
        -- and Note [Substituting types and coercions]

-- | A substitution of 'Type's for 'TyVar's
--                 and 'Kind's for 'KindVar's
type TvSubstEnv = TyVarEnv Type
        -- A TvSubstEnv is used both inside a TCvSubst (with the apply-once
        -- invariant discussed in Note [Apply Once]), and also independently
        -- in the middle of matching, and unification (see Types.Unify)
        -- So you have to look at the context to know if it's idempotent or
        -- apply-once or whatever

-- | A substitution of 'Coercion's for 'CoVar's
type CvSubstEnv = CoVarEnv Coercion

{-
Note [Apply Once]
~~~~~~~~~~~~~~~~~
We use TCvSubsts to instantiate things, and we might instantiate
        forall a b. ty
\with the types
        [a, b], or [b, a].
So the substitution might go [a->b, b->a].  A similar situation arises in Core
when we find a beta redex like
        (/\ a /\ b -> e) b a
Then we also end up with a substitution that permutes type variables. Other
variations happen to; for example [a -> (a, b)].

        ****************************************************
        *** So a TCvSubst must be applied precisely once ***
        ****************************************************

A TCvSubst is not idempotent, but, unlike the non-idempotent substitution
we use during unifications, it must not be repeatedly applied.

Note [Extending the TvSubstEnv]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
See #tcvsubst_invariant# for the invariants that must hold.

This invariant allows a short-cut when the subst envs are empty:
if the TvSubstEnv and CvSubstEnv are empty --- i.e. (isEmptyTCvSubst subst)
holds --- then (substTy subst ty) does nothing.

For example, consider:
        (/\a. /\b:(a~Int). ...b..) Int
We substitute Int for 'a'.  The Unique of 'b' does not change, but
nevertheless we add 'b' to the TvSubstEnv, because b's kind does change

This invariant has several crucial consequences:

* In substTyVarBndr, we need extend the TvSubstEnv
        - if the unique has changed
        - or if the kind has changed

* In substTyVar, we do not need to consult the in-scope set;
  the TvSubstEnv is enough

* In substTy, substTheta, we can short-circuit when the TvSubstEnv is empty

Note [Substituting types and coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Types and coercions are mutually recursive, and either may have variables
"belonging" to the other. Thus, every time we wish to substitute in a
type, we may also need to substitute in a coercion, and vice versa.
However, the constructor used to create type variables is distinct from
that of coercion variables, so we carry two VarEnvs in a TCvSubst. Note
that it would be possible to use the CoercionTy constructor to combine
these environments, but that seems like a false economy.

Note that the TvSubstEnv should *never* map a CoVar (built with the Id
constructor) and the CvSubstEnv should *never* map a TyVar. Furthermore,
the range of the TvSubstEnv should *never* include a type headed with
CoercionTy.
-}

emptyTvSubstEnv :: TvSubstEnv
emptyTvSubstEnv = emptyVarEnv

emptyCvSubstEnv :: CvSubstEnv
emptyCvSubstEnv = emptyVarEnv

composeTCvSubstEnv :: InScopeSet
                   -> (TvSubstEnv, CvSubstEnv)
                   -> (TvSubstEnv, CvSubstEnv)
                   -> (TvSubstEnv, CvSubstEnv)
-- ^ @(compose env1 env2)(x)@ is @env1(env2(x))@; i.e. apply @env2@ then @env1@.
-- It assumes that both are idempotent.
-- Typically, @env1@ is the refinement to a base substitution @env2@
composeTCvSubstEnv in_scope (tenv1, cenv1) (tenv2, cenv2)
  = ( tenv1 `plusVarEnv` mapVarEnv (substTy subst1) tenv2
    , cenv1 `plusVarEnv` mapVarEnv (substCo subst1) cenv2 )
        -- First apply env1 to the range of env2
        -- Then combine the two, making sure that env1 loses if
        -- both bind the same variable; that's why env1 is the
        --  *left* argument to plusVarEnv, because the right arg wins
  where
    subst1 = TCvSubst in_scope tenv1 cenv1

-- | Composes two substitutions, applying the second one provided first,
-- like in function composition.
composeTCvSubst :: TCvSubst -> TCvSubst -> TCvSubst
composeTCvSubst (TCvSubst is1 tenv1 cenv1) (TCvSubst is2 tenv2 cenv2)
  = TCvSubst is3 tenv3 cenv3
  where
    is3 = is1 `unionInScope` is2
    (tenv3, cenv3) = composeTCvSubstEnv is3 (tenv1, cenv1) (tenv2, cenv2)

emptyTCvSubst :: TCvSubst
emptyTCvSubst = TCvSubst emptyInScopeSet emptyTvSubstEnv emptyCvSubstEnv

mkEmptyTCvSubst :: InScopeSet -> TCvSubst
mkEmptyTCvSubst is = TCvSubst is emptyTvSubstEnv emptyCvSubstEnv

isEmptyTCvSubst :: TCvSubst -> Bool
         -- See Note [Extending the TvSubstEnv]
isEmptyTCvSubst (TCvSubst _ tenv cenv) = isEmptyVarEnv tenv && isEmptyVarEnv cenv

mkTCvSubst :: InScopeSet -> (TvSubstEnv, CvSubstEnv) -> TCvSubst
mkTCvSubst in_scope (tenv, cenv) = TCvSubst in_scope tenv cenv

getTvSubstEnv :: TCvSubst -> TvSubstEnv
getTvSubstEnv (TCvSubst _ env _) = env

getCvSubstEnv :: TCvSubst -> CvSubstEnv
getCvSubstEnv (TCvSubst _ _ env) = env

getTCvInScope :: TCvSubst -> InScopeSet
getTCvInScope (TCvSubst in_scope _ _) = in_scope

isInScope :: Var -> TCvSubst -> Bool
isInScope v (TCvSubst in_scope _ _) = v `elemInScopeSet` in_scope

notElemTCvSubst :: Var -> TCvSubst -> Bool
notElemTCvSubst v (TCvSubst _ tenv cenv)
  | isTyVar v
  = not (v `elemVarEnv` tenv)
  | otherwise
  = not (v `elemVarEnv` cenv)

setTvSubstEnv :: TCvSubst -> TvSubstEnv -> TCvSubst
setTvSubstEnv (TCvSubst in_scope _ cenv) tenv = TCvSubst in_scope tenv cenv

setCvSubstEnv :: TCvSubst -> CvSubstEnv -> TCvSubst
setCvSubstEnv (TCvSubst in_scope tenv _) cenv = TCvSubst in_scope tenv cenv

zapTCvSubst :: TCvSubst -> TCvSubst
zapTCvSubst (TCvSubst in_scope _ _) = TCvSubst in_scope emptyVarEnv emptyVarEnv

extendTCvInScope :: TCvSubst -> Var -> TCvSubst
extendTCvInScope (TCvSubst in_scope tenv cenv) var
  = TCvSubst (extendInScopeSet in_scope var) tenv cenv

extendTCvInScopeList :: TCvSubst -> [Var] -> TCvSubst
extendTCvInScopeList (TCvSubst in_scope tenv cenv) vars
  = TCvSubst (extendInScopeSetList in_scope vars) tenv cenv

extendTCvInScopeSet :: TCvSubst -> VarSet -> TCvSubst
extendTCvInScopeSet (TCvSubst in_scope tenv cenv) vars
  = TCvSubst (extendInScopeSetSet in_scope vars) tenv cenv

extendSubstEnvs :: (TvSubstEnv, CvSubstEnv) -> Var -> Type
                -> (TvSubstEnv, CvSubstEnv)
extendSubstEnvs (tenv, cenv) v ty
  | isTyVar v
  = ASSERT( not $ isCoercionTy ty )
    (extendVarEnv tenv v ty, cenv)

    -- NB: v might *not* be a proper covar, because it might be lifted.
    -- This happens in tcCoercionToCoercion
  | CoercionTy co <- ty
  = (tenv, extendVarEnv cenv v co)
  | otherwise
  = pprPanic "extendSubstEnvs" (ppr v <+> ptext (sLit "|->") <+> ppr ty)

extendTCvSubst :: TCvSubst -> Var -> Type -> TCvSubst
extendTCvSubst (TCvSubst in_scope tenv cenv) tv ty
  = TCvSubst in_scope tenv' cenv'
  where (tenv', cenv') = extendSubstEnvs (tenv, cenv) tv ty

extendTCvSubstAndInScope :: TCvSubst -> TyCoVar -> Type -> TCvSubst
-- Also extends the in-scope set
extendTCvSubstAndInScope (TCvSubst in_scope tenv cenv) tv ty
  = TCvSubst (in_scope `extendInScopeSetSet` tyCoVarsOfType ty)
             tenv' cenv'
  where (tenv', cenv') = extendSubstEnvs (tenv, cenv) tv ty

extendTCvSubstList :: TCvSubst -> [Var] -> [Type] -> TCvSubst
extendTCvSubstList subst tvs tys
  = foldl2 extendTCvSubst subst tvs tys

extendTCvSubstBinder :: TCvSubst -> Binder -> Type -> TCvSubst
extendTCvSubstBinder env (Anon {})    _  = env
extendTCvSubstBinder env (Named tv _) ty = extendTCvSubst env tv ty

unionTCvSubst :: TCvSubst -> TCvSubst -> TCvSubst
-- Works when the ranges are disjoint
unionTCvSubst (TCvSubst in_scope1 tenv1 cenv1) (TCvSubst in_scope2 tenv2 cenv2)
  = ASSERT( not (tenv1 `intersectsVarEnv` tenv2)
         && not (cenv1 `intersectsVarEnv` cenv2) )
    TCvSubst (in_scope1 `unionInScope` in_scope2)
             (tenv1     `plusVarEnv`   tenv2)
             (cenv1     `plusVarEnv`   cenv2)

-- mkOpenTCvSubst and zipOpenTCvSubst generate the in-scope set from
-- the types given; but it's just a thunk so with a bit of luck
-- it'll never be evaluated

-- Note [Generating the in-scope set for a substitution]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- If we want to substitute [a -> ty1, b -> ty2] I used to
-- think it was enough to generate an in-scope set that includes
-- fv(ty1,ty2).  But that's not enough; we really should also take the
-- free vars of the type we are substituting into!  Example:
--      (forall b. (a,b,x)) [a -> List b]
-- Then if we use the in-scope set {b}, there is a danger we will rename
-- the forall'd variable to 'x' by mistake, getting this:
--      (forall x. (List b, x, x))
-- Urk!  This means looking at all the calls to mkOpenTCvSubst....


-- | Generates an in-scope set from the free variables in a list of types
-- and a list of coercions
mkTyCoInScopeSet :: [Type] -> [Coercion] -> InScopeSet
mkTyCoInScopeSet tys cos
  = mkInScopeSet (tyCoVarsOfTypes tys `unionVarSet` tyCoVarsOfCos cos)

-- | Generates the in-scope set for the 'TCvSubst' from the types in the incoming
-- environment, hence "open"
mkOpenTCvSubst :: TvSubstEnv -> CvSubstEnv -> TCvSubst
mkOpenTCvSubst tenv cenv
  = TCvSubst (mkTyCoInScopeSet (varEnvElts tenv) (varEnvElts cenv)) tenv cenv

-- | Generates the in-scope set for the 'TCvSubst' from the types in the incoming
-- environment, hence "open". No CoVars, please!
zipOpenTCvSubst :: [TyVar] -> [Type] -> TCvSubst
zipOpenTCvSubst tyvars tys
  | debugIsOn && (length tyvars /= length tys)
  = pprTrace "zipOpenTCvSubst" (ppr tyvars $$ ppr tys) emptyTCvSubst
  | otherwise
  = TCvSubst (mkInScopeSet (tyCoVarsOfTypes tys)) tenv emptyCvSubstEnv
  where tenv = zipTyEnv tyvars tys

-- | Generates the in-scope set for the 'TCvSubst' from the types in the incoming
-- environment, hence "open".
zipOpenTCvSubstCoVars :: [CoVar] -> [Coercion] -> TCvSubst
zipOpenTCvSubstCoVars cvs cos
  | debugIsOn && (length cvs /= length cos)
  = pprTrace "zipOpenTCvSubstCoVars" (ppr cvs $$ ppr cos) emptyTCvSubst
  | otherwise
  = TCvSubst (mkInScopeSet (tyCoVarsOfCos cos)) emptyTvSubstEnv cenv
  where cenv = zipCoEnv cvs cos


-- | Create an open TCvSubst combining the binders and types provided.
-- NB: It is OK if the lists are of different lengths.
zipOpenTCvSubstBinders :: [Binder] -> [Type] -> TCvSubst
zipOpenTCvSubstBinders bndrs tys
  = TCvSubst is tenv emptyCvSubstEnv
  where
    is = mkInScopeSet (tyCoVarsOfTypes tys)
    (tvs, tys') = unzip [ (tv, ty) | (Named tv _, ty) <- zip bndrs tys ]
    tenv = zipTyEnv tvs tys'

-- | Called when doing top-level substitutions. Here we expect that the
-- free vars of the range of the substitution will be empty.
mkTopTCvSubst :: [(TyCoVar, Type)] -> TCvSubst
mkTopTCvSubst prs = TCvSubst emptyInScopeSet tenv cenv
  where (tenv, cenv) = foldl extend (emptyTvSubstEnv, emptyCvSubstEnv) prs
        extend envs (v, ty) = extendSubstEnvs envs v ty

-- | Makes a subst with an empty in-scope-set. No CoVars, please!
zipTopTCvSubst :: [TyVar] -> [Type] -> TCvSubst
zipTopTCvSubst tyvars tys
  | debugIsOn && (length tyvars /= length tys)
  = pprTrace "zipTopTCvSubst" (ppr tyvars $$ ppr tys) emptyTCvSubst
  | otherwise
  = TCvSubst emptyInScopeSet tenv emptyCvSubstEnv
  where tenv = zipTyEnv tyvars tys

zipTyEnv :: [TyVar] -> [Type] -> TvSubstEnv
zipTyEnv tyvars tys
  = ASSERT( all (not . isCoercionTy) tys )
    mkVarEnv (zipEqual "zipTyEnv" tyvars tys)
        -- There used to be a special case for when
        --      ty == TyVarTy tv
        -- (a not-uncommon case) in which case the substitution was dropped.
        -- But the type-tidier changes the print-name of a type variable without
        -- changing the unique, and that led to a bug.   Why?  Pre-tidying, we had
        -- a type {Foo t}, where Foo is a one-method class.  So Foo is really a newtype.
        -- And it happened that t was the type variable of the class.  Post-tiding,
        -- it got turned into {Foo t2}.  The ext-core printer expanded this using
        -- sourceTypeRep, but that said "Oh, t == t2" because they have the same unique,
        -- and so generated a rep type mentioning t not t2.
        --
        -- Simplest fix is to nuke the "optimisation"

zipCoEnv :: [CoVar] -> [Coercion] -> CvSubstEnv
zipCoEnv cvs cos = mkVarEnv (zipEqual "zipCoEnv" cvs cos)

instance Outputable TCvSubst where
  ppr (TCvSubst ins tenv cenv)
    = brackets $ sep[ ptext (sLit "TCvSubst"),
                      nest 2 (ptext (sLit "In scope:") <+> ppr ins),
                      nest 2 (ptext (sLit "Type env:") <+> ppr tenv),
                      nest 2 (ptext (sLit "Co env:") <+> ppr cenv) ]

{-
%************************************************************************
%*                                                                      *
                Performing type or kind substitutions
%*                                                                      *
%************************************************************************

Note [Sym and ForAllCo]
~~~~~~~~~~~~~~~~~~~~~~~
In OptCoercion, we try to push "sym" out to the leaves of a coercion. But,
how do we push sym into a ForAllCo? It's a little ugly.

Here is the typing rule:

h : k1 ~# k2
(tv : k1) |- g : ty1 ~# ty2
----------------------------
ForAllCo tv h g : (ForAllTy (tv : k1) ty1) ~#
                  (ForAllTy (tv : k2) (ty2[tv |-> tv |> sym h]))

Here is what we want:

ForAllCo tv h' g' : (ForAllTy (tv : k2) (ty2[tv |-> tv |> sym h])) ~#
                    (ForAllTy (tv : k1) ty1)


Because the kinds of the type variables to the right of the colon are the kinds
coerced by h', we know (h' : k2 ~# k1). Thus, (h' = sym h).

Now, we can rewrite ty1 to be (ty1[tv |-> tv |> sym h' |> h']). We thus want

ForAllCo tv h' g' :
  (ForAllTy (tv : k2) (ty2[tv |-> tv |> h'])) ~#
  (ForAllTy (tv : k1) (ty1[tv |-> tv |> h'][tv |-> tv |> sym h']))

We thus see that we want

g' : ty2[tv |-> tv |> h'] ~# ty1[tv |-> tv |> h']

and thus g' = sym (g[tv |-> tv |> h']).

Putting it all together, we get this:

sym (ForAllCo tv h g)
==>
ForAllCo tv (sym h) (sym g[tv |-> tv |> sym h])

-}

-- | Create a substitution from tyvars to types, but later types may depend
-- on earlier ones. Return the substed types and the built substitution.
substTelescope :: [TyCoVar] -> [Type] -> ([Type], TCvSubst)
substTelescope = go_subst emptyTCvSubst
  where
    go_subst :: TCvSubst -> [TyCoVar] -> [Type] -> ([Type], TCvSubst)
    go_subst subst [] [] = ([], subst)
    go_subst subst (tv:tvs) (k:ks)
      = let k' = substTy subst k in
        liftFst (k' :) $ go_subst (extendTCvSubst subst tv k') tvs ks
    go_subst _ _ _ = panic "substTelescope"


-- | Type substitution making use of an 'TCvSubst' that
-- is assumed to be open, see 'zipOpenTCvSubst'
substTyWith :: [TyVar] -> [Type] -> Type -> Type
substTyWith tvs tys = ASSERT( length tvs == length tys )
                      substTy (zipOpenTCvSubst tvs tys)

-- | Coercion substitution making use of an 'TCvSubst' that
-- is assumed to be open, see 'zipOpenTCvSubst'
substCoWith :: [TyVar] -> [Type] -> Coercion -> Coercion
substCoWith tvs tys = ASSERT( length tvs == length tys )
                      substCo (zipOpenTCvSubst tvs tys)

-- | Substitute covars within a type
substTyWithCoVars :: [CoVar] -> [Coercion] -> Type -> Type
substTyWithCoVars cvs cos = substTy (zipOpenTCvSubstCoVars cvs cos)

-- | Type substitution making use of an 'TCvSubst' that
-- is assumed to be open, see 'zipOpenTCvSubst'
substTysWith :: [TyVar] -> [Type] -> [Type] -> [Type]
substTysWith tvs tys = ASSERT( length tvs == length tys )
                       substTys (zipOpenTCvSubst tvs tys)

-- | Type substitution making use of an 'TCvSubst' that
-- is assumed to be open, see 'zipOpenTCvSubst'
substTysWithCoVars :: [CoVar] -> [Coercion] -> [Type] -> [Type]
substTysWithCoVars cvs cos = ASSERT( length cvs == length cos )
                             substTys (zipOpenTCvSubstCoVars cvs cos)

-- | Type substitution using 'Binder's. Anonymous binders
-- simply ignore their matching type.
substTyWithBinders :: [Binder] -> [Type] -> Type -> Type
substTyWithBinders bndrs tys = ASSERT( length bndrs == length tys )
                               substTy (zipOpenTCvSubstBinders bndrs tys)

-- | Substitute within a 'Type'
substTy :: TCvSubst -> Type  -> Type
substTy subst ty | isEmptyTCvSubst subst = ty
                 | otherwise             = subst_ty subst ty

-- | Substitute within several 'Type's
substTys :: TCvSubst -> [Type] -> [Type]
substTys subst tys | isEmptyTCvSubst subst = tys
                   | otherwise             = map (subst_ty subst) tys

-- | Substitute within a 'ThetaType'
substTheta :: TCvSubst -> ThetaType -> ThetaType
substTheta = substTys

subst_ty :: TCvSubst -> Type -> Type
-- subst_ty is the main workhorse for type substitution
--
-- Note that the in_scope set is poked only if we hit a forall
-- so it may often never be fully computed
subst_ty subst ty
   = go ty
  where
    go (TyVarTy tv)      = substTyVar subst tv
    go (AppTy fun arg)   = mkAppTy (go fun) $! (go arg)
                -- The mkAppTy smart constructor is important
                -- we might be replacing (a Int), represented with App
                -- by [Int], represented with TyConApp
    go (TyConApp tc tys) = let args = map go tys
                           in  args `seqList` TyConApp tc args
    go (ForAllTy (Anon arg) res)
                         = (ForAllTy $! (Anon $! go arg)) $! go res
    go (ForAllTy (Named tv vis) ty)
                         = case substTyVarBndr subst tv of
                             (subst', tv') ->
                               (ForAllTy $! ((Named $! tv') vis)) $!
                                            (subst_ty subst' ty)
    go (LitTy n)         = LitTy $! n
    go (CastTy ty co)    = (CastTy $! (go ty)) $! (subst_co subst co)
    go (CoercionTy co)   = CoercionTy $! (subst_co subst co)

substTyVar :: TCvSubst -> TyVar -> Type
substTyVar (TCvSubst _ tenv _) tv
  = ASSERT( isTyVar tv )
    case lookupVarEnv tenv tv of
      Just ty -> ty
      Nothing -> TyVarTy tv

substTyVars :: TCvSubst -> [TyVar] -> [Type]
substTyVars subst = map $ substTyVar subst

lookupTyVar :: TCvSubst -> TyVar  -> Maybe Type
        -- See Note [Extending the TCvSubst]
lookupTyVar (TCvSubst _ tenv _) tv
  = ASSERT( isTyVar tv )
    lookupVarEnv tenv tv

-- | Substitute within a 'Coercion'
substCo :: TCvSubst -> Coercion -> Coercion
substCo subst co | isEmptyTCvSubst subst = co
                 | otherwise             = subst_co subst co

-- | Substitute within several 'Coercion's
substCos :: TCvSubst -> [Coercion] -> [Coercion]
substCos subst cos | isEmptyTCvSubst subst = cos
                   | otherwise             = map (substCo subst) cos

subst_co :: TCvSubst -> Coercion -> Coercion
subst_co subst co
  = go co
  where
    go_ty :: Type -> Type
    go_ty = subst_ty subst

    go :: Coercion -> Coercion
    go (Refl r ty)           = mkReflCo r $! go_ty ty
    go (TyConAppCo r tc args)= let args' = map go args
                               in  args' `seqList` mkTyConAppCo r tc args'
    go (AppCo co arg)        = (mkAppCo $! go co) $! go arg
    go (ForAllCo tv kind_co co)
      = case substForAllCoBndr subst tv kind_co of { (subst', tv', kind_co') ->
          ((mkForAllCo $! tv') $! kind_co') $! subst_co subst' co }
    go (CoVarCo cv)          = substCoVar subst cv
    go (AxiomInstCo con ind cos) = mkAxiomInstCo con ind $! map go cos
    go (UnivCo p r t1 t2)    = (((mkUnivCo $! go_prov p) $! r) $!
                                (go_ty t1)) $! (go_ty t2)
    go (SymCo co)            = mkSymCo $! (go co)
    go (TransCo co1 co2)     = (mkTransCo $! (go co1)) $! (go co2)
    go (NthCo d co)          = mkNthCo d $! (go co)
    go (LRCo lr co)          = mkLRCo lr $! (go co)
    go (InstCo co arg)       = (mkInstCo $! (go co)) $! go arg
    go (CoherenceCo co1 co2) = (mkCoherenceCo $! (go co1)) $! (go co2)
    go (KindCo co)           = mkKindCo $! (go co)
    go (SubCo co)            = mkSubCo $! (go co)
    go (AxiomRuleCo c cs)    = let cs1 = map go cs
                                in cs1 `seqList` AxiomRuleCo c cs1

    go_prov UnsafeCoerceProv     = UnsafeCoerceProv
    go_prov (PhantomProv kco)    = PhantomProv (go kco)
    go_prov (ProofIrrelProv kco) = ProofIrrelProv (go kco)
    go_prov p@(PluginProv _)     = p
    go_prov (HoleProv h)         = pprPanic "subst_co fell into a hole)" (ppr h)

substForAllCoBndr :: TCvSubst -> TyVar -> Coercion -> (TCvSubst, TyVar, Coercion)
substForAllCoBndr subst
  = substForAllCoBndrCallback False (substCo subst) subst

-- See Note [Sym and ForAllCo]
substForAllCoBndrCallback :: Bool  -- apply sym to binder?
                          -> (Coercion -> Coercion)  -- transformation to kind co
                          -> TCvSubst -> TyVar -> Coercion
                          -> (TCvSubst, TyVar, Coercion)
substForAllCoBndrCallback sym sco (TCvSubst in_scope tenv cenv)
                          old_var old_kind_co
  = ( TCvSubst (in_scope `extendInScopeSet` new_var) new_env cenv
    , new_var, new_kind_co )
  where
    new_env | no_change && not sym = delVarEnv tenv old_var
            | sym       = extendVarEnv tenv old_var $
                            TyVarTy new_var `CastTy` new_kind_co
            | otherwise = extendVarEnv tenv old_var (TyVarTy new_var)

    no_kind_change = isEmptyVarSet (tyCoVarsOfCo old_kind_co)
    no_change = no_kind_change && (new_var == old_var)

    new_kind_co | no_kind_change = old_kind_co
                | otherwise      = sco old_kind_co

    Pair new_ki1 _ = coercionKind new_kind_co

    new_var  = uniqAway in_scope (setTyVarKind old_var new_ki1)

substCoVar :: TCvSubst -> CoVar -> Coercion
substCoVar (TCvSubst _ _ cenv) cv
  = case lookupVarEnv cenv cv of
      Just co -> co
      Nothing -> CoVarCo cv

substCoVars :: TCvSubst -> [CoVar] -> [Coercion]
substCoVars subst cvs = map (substCoVar subst) cvs

lookupCoVar :: TCvSubst -> Var  -> Maybe Coercion
lookupCoVar (TCvSubst _ _ cenv) v = lookupVarEnv cenv v

substTyVarBndr :: TCvSubst -> TyVar -> (TCvSubst, TyVar)
substTyVarBndr = substTyVarBndrCallback substTy

-- | Substitute a tyvar in a binding position, returning an
-- extended subst and a new tyvar.
substTyVarBndrCallback :: (TCvSubst -> Type -> Type)  -- ^ the subst function
                       -> TCvSubst -> TyVar -> (TCvSubst, TyVar)
substTyVarBndrCallback subst_fn subst@(TCvSubst in_scope tenv cenv) old_var
  = ASSERT2( _no_capture, ppr old_var $$ ppr subst )
    ASSERT( isTyVar old_var )
    (TCvSubst (in_scope `extendInScopeSet` new_var) new_env cenv, new_var)
  where
    new_env | no_change = delVarEnv tenv old_var
            | otherwise = extendVarEnv tenv old_var (TyVarTy new_var)

    _no_capture = not (new_var `elemVarSet` tyCoVarsOfTypes (varEnvElts tenv))
    -- Assertion check that we are not capturing something in the substitution

    old_ki = tyVarKind old_var
    no_kind_change = isEmptyVarSet (tyCoVarsOfType old_ki) -- verify that kind is closed
    no_change = no_kind_change && (new_var == old_var)
        -- no_change means that the new_var is identical in
        -- all respects to the old_var (same unique, same kind)
        -- See Note [Extending the TCvSubst]
        --
        -- In that case we don't need to extend the substitution
        -- to map old to new.  But instead we must zap any
        -- current substitution for the variable. For example:
        --      (\x.e) with id_subst = [x |-> e']
        -- Here we must simply zap the substitution for x

    new_var | no_kind_change = uniqAway in_scope old_var
            | otherwise = uniqAway in_scope $ updateTyVarKind (subst_fn subst) old_var
        -- The uniqAway part makes sure the new variable is not already in scope

substCoVarBndr :: TCvSubst -> CoVar -> (TCvSubst, CoVar)
substCoVarBndr = substCoVarBndrCallback False substTy

substCoVarBndrCallback :: Bool -- apply "sym" to the covar?
                       -> (TCvSubst -> Type -> Type)
                       -> TCvSubst -> CoVar -> (TCvSubst, CoVar)
substCoVarBndrCallback sym subst_fun subst@(TCvSubst in_scope tenv cenv) old_var
  = ASSERT( isCoVar old_var )
    (TCvSubst (in_scope `extendInScopeSet` new_var) tenv new_cenv, new_var)
  where
    -- When we substitute (co :: t1 ~ t2) we may get the identity (co :: t ~ t)
    -- In that case, mkCoVarCo will return a ReflCoercion, and
    -- we want to substitute that (not new_var) for old_var
    new_co    = (if sym then mkSymCo else id) $ mkCoVarCo new_var
    no_kind_change = isEmptyVarSet (tyCoVarsOfTypes [t1, t2])
    no_change = new_var == old_var && not (isReflCo new_co) && no_kind_change

    new_cenv | no_change = delVarEnv cenv old_var
             | otherwise = extendVarEnv cenv old_var new_co

    new_var = uniqAway in_scope subst_old_var
    subst_old_var = mkCoVar (varName old_var) new_var_type

    (_, _, t1, t2, role) = coVarKindsTypesRole old_var
    t1' = subst_fun subst t1
    t2' = subst_fun subst t2
    new_var_type = uncurry (mkCoercionType role) (if sym then (t2', t1') else (t1', t2'))
                  -- It's important to do the substitution for coercions,
                  -- because they can have free type variables

cloneTyVarBndr :: TCvSubst -> TyVar -> Unique -> (TCvSubst, TyVar)
cloneTyVarBndr (TCvSubst in_scope tv_env cv_env) tv uniq
  | isTyVar tv
  = (TCvSubst (extendInScopeSet in_scope tv')
              (extendVarEnv tv_env tv (mkTyVarTy tv')) cv_env, tv')
  | otherwise
  = (TCvSubst (extendInScopeSet in_scope tv')
              tv_env (extendVarEnv cv_env tv (mkCoVarCo tv')), tv')
  where
    tv' = setVarUnique tv uniq  -- Simply set the unique; the kind
                                -- has no type variables to worry about

{-
%************************************************************************
%*                                                                      *
                   Pretty-printing types

       Defined very early because of debug printing in assertions
%*                                                                      *
%************************************************************************

@pprType@ is the standard @Type@ printer; the overloaded @ppr@ function is
defined to use this.  @pprParendType@ is the same, except it puts
parens around the type, except for the atomic cases.  @pprParendType@
works just by setting the initial context precedence very high.

Note [Precedence in types]
~~~~~~~~~~~~~~~~~~~~~~~~~~
We don't keep the fixity of type operators in the operator. So the pretty printer
operates the following precedene structre:
   Type constructor application   binds more tightly than
   Oerator applications           which bind more tightly than
   Function arrow

So we might see  a :+: T b -> c
meaning          (a :+: (T b)) -> c

Maybe operator applications should bind a bit less tightly?

Anyway, that's the current story, and it is used consistently for Type and HsType
-}

data TyPrec   -- See Note [Prededence in types]
  = TopPrec         -- No parens
  | FunPrec         -- Function args; no parens for tycon apps
  | TyOpPrec        -- Infix operator
  | TyConPrec       -- Tycon args; no parens for atomic
  deriving( Eq, Ord )

maybeParen :: TyPrec -> TyPrec -> SDoc -> SDoc
maybeParen ctxt_prec inner_prec pretty
  | ctxt_prec < inner_prec = pretty
  | otherwise              = parens pretty

------------------
pprType, pprParendType :: Type -> SDoc
pprType       ty = ppr_type TopPrec ty
pprParendType ty = ppr_type TyConPrec ty

pprTyLit :: TyLit -> SDoc
pprTyLit = ppr_tylit TopPrec

pprKind, pprParendKind :: Kind -> SDoc
pprKind       = pprType
pprParendKind = pprParendType

------------
pprClassPred :: Class -> [Type] -> SDoc
pprClassPred clas tys = pprTypeApp (classTyCon clas) tys

------------
pprTheta :: ThetaType -> SDoc
pprTheta [pred] = ppr_type TopPrec pred     -- I'm in two minds about this
pprTheta theta  = parens (sep (punctuate comma (map (ppr_type TopPrec) theta)))

pprThetaArrowTy :: ThetaType -> SDoc
pprThetaArrowTy []     = empty
pprThetaArrowTy [pred] = ppr_type TyOpPrec pred <+> darrow
                         -- TyOpPrec:  Num a     => a -> a  does not need parens
                         --      bug   (a :~: b) => a -> b  currently does
                         -- Trac # 9658
pprThetaArrowTy preds  = parens (fsep (punctuate comma (map (ppr_type TopPrec) preds)))
                            <+> darrow
    -- Notice 'fsep' here rather that 'sep', so that
    -- type contexts don't get displayed in a giant column
    -- Rather than
    --  instance (Eq a,
    --            Eq b,
    --            Eq c,
    --            Eq d,
    --            Eq e,
    --            Eq f,
    --            Eq g,
    --            Eq h,
    --            Eq i,
    --            Eq j,
    --            Eq k,
    --            Eq l) =>
    --           Eq (a, b, c, d, e, f, g, h, i, j, k, l)
    -- we get
    --
    --  instance (Eq a, Eq b, Eq c, Eq d, Eq e, Eq f, Eq g, Eq h, Eq i,
    --            Eq j, Eq k, Eq l) =>
    --           Eq (a, b, c, d, e, f, g, h, i, j, k, l)

------------------
instance Outputable Type where
    ppr ty = pprType ty

instance Outputable TyLit where
   ppr = pprTyLit

------------------
        -- OK, here's the main printer

ppr_type :: TyPrec -> Type -> SDoc
ppr_type _ (TyVarTy tv)       = ppr_tvar tv

ppr_type p (TyConApp tc tys)  = pprTyTcApp p tc tys
ppr_type p (LitTy l)          = ppr_tylit p l
ppr_type p ty@(ForAllTy {})   = ppr_forall_type p ty

ppr_type p (AppTy t1 t2) = maybeParen p TyConPrec $
                           ppr_type FunPrec t1 <+> ppr_type TyConPrec t2

ppr_type p (CastTy ty co)
  = sdocWithDynFlags $ \dflags ->
  -- TODO (RAE): PrintExplicitCoercions? PrintInvisibles?
    if gopt Opt_PrintExplicitKinds dflags
    then parens (ppr_type TopPrec ty <+> ptext (sLit "|>") <+> ppr co)
    else ppr_type p ty

ppr_type _ (CoercionTy co)
  = parens (ppr co) -- TODO (RAE): do we need these parens?

ppr_forall_type :: TyPrec -> Type -> SDoc
ppr_forall_type p ty
  = maybeParen p FunPrec $ ppr_sigma_type True ty
    -- True <=> we always print the foralls on *nested* quantifiers
    -- Opt_PrintExplicitForalls only affects top-level quantifiers
    -- False <=> we don't print an extra-constraints wildcard

ppr_tvar :: TyVar -> SDoc
ppr_tvar tv  -- Note [Infix type variables]
  = parenSymOcc (getOccName tv) (ppr tv)

ppr_tylit :: TyPrec -> TyLit -> SDoc
ppr_tylit _ tl =
  case tl of
    NumTyLit n -> integer n
    StrTyLit s -> text (show s)

-------------------
ppr_sigma_type :: Bool -> Type -> SDoc
-- First Bool <=> Show the foralls unconditionally
-- Second Bool <=> Show an extra-constraints wildcard
ppr_sigma_type show_foralls_unconditionally ty
  = sep [ if   show_foralls_unconditionally
          then pprForAll bndrs
          else pprUserForAll bndrs
        , pprThetaArrowTy ctxt
        , pprArrowChain TopPrec (ppr_fun_tail tau) ]
  where
    (bndrs, rho) = split1 [] ty
    (ctxt, tau)  = split2 [] rho

    split1 bndrs (ForAllTy bndr@(Named {}) ty) = split1 (bndr:bndrs) ty
    split1 bndrs ty                            = (reverse bndrs, ty)

    split2 ps (ForAllTy (Anon ty1) ty2) | isPredTy ty1 = split2 (ty1:ps) ty2
    split2 ps ty                                       = (reverse ps, ty)

    -- We don't want to lose synonyms, so we mustn't use splitFunTys here.
    ppr_fun_tail (ForAllTy (Anon ty1) ty2)
      | not (isPredTy ty1) = ppr_type FunPrec ty1 : ppr_fun_tail ty2
    ppr_fun_tail other_ty = [ppr_type TopPrec other_ty]

pprSigmaType :: Type -> SDoc
pprSigmaType ty = ppr_sigma_type False ty

pprUserForAll :: [Binder] -> SDoc
-- Print a user-level forall; see Note [When to print foralls]
pprUserForAll bndrs
  = sdocWithDynFlags $ \dflags ->
    ppWhen (any bndr_has_kind_var bndrs || gopt Opt_PrintExplicitForalls dflags) $
    pprForAll bndrs
  where
    bndr_has_kind_var bndr
      = not (isEmptyVarSet (tyCoVarsOfType (binderType bndr)))

pprForAllImplicit :: [TyVar] -> SDoc
pprForAllImplicit tvs = pprForAll (zipWith Named tvs (repeat Invisible))

-- | Render the "forall ... ." or "forall ... ->" bit of a type.
-- Do not pass in anonymous binders!
pprForAll :: [Binder] -> SDoc
pprForAll [] = empty
pprForAll bndrs@(Named _ vis : _)
  = add_separator (forAllLit <+> doc) <+> pprForAll bndrs'
  where
    (bndrs', doc) = ppr_tv_bndrs bndrs vis

    add_separator stuff = case vis of
                            Invisible -> stuff <>  dot
                            Visible   -> stuff <+> arrow
pprForAll bndrs = pprPanic "pprForAll: anonymous binder" (ppr bndrs)

pprTvBndrs :: [TyVar] -> SDoc
pprTvBndrs tvs = sep (map pprTvBndr tvs)

-- | Render the ... in @(forall ... .)@ or @(forall ... ->)@.
-- Returns both the list of not-yet-rendered binders and the doc.
-- No anonymous binders here!
ppr_tv_bndrs :: [Binder]
             -> VisibilityFlag  -- ^ visibility of the first binder in the list
             -> ([Binder], SDoc)
ppr_tv_bndrs all_bndrs@(Named tv vis : bndrs) vis1
  | vis == vis1 = let (bndrs', doc) = ppr_tv_bndrs bndrs vis1 in
                  (bndrs', pprTvBndr tv <+> doc)
  | otherwise   = (all_bndrs, empty)
ppr_tv_bndrs [] _ = ([], empty)
ppr_tv_bndrs bndrs _ = pprPanic "ppr_tv_bndrs: anonymous binder" (ppr bndrs)

pprTvBndr :: TyVar -> SDoc
pprTvBndr tv
  | isLiftedTypeKind kind = ppr_tvar tv
  | otherwise             = parens (ppr_tvar tv <+> dcolon <+> pprKind kind)
             where
               kind = tyVarKind tv

instance Outputable Binder where
  ppr (Named v Visible)   = ppr v
  ppr (Named v Invisible) = braces (ppr v)
  ppr (Anon ty)       = text "[anon]" <+> ppr ty

instance Outputable VisibilityFlag where
  ppr Visible   = text "[vis]"
  ppr Invisible = text "[invis]"

-----------------
instance Outputable Coercion where -- defined here to avoid orphans
  ppr = pprCo
instance Outputable LeftOrRight where
  ppr CLeft    = ptext (sLit "Left")
  ppr CRight   = ptext (sLit "Right")

{-
Note [When to print foralls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Mostly we want to print top-level foralls when (and only when) the user specifies
-fprint-explicit-foralls.  But when kind polymorphism is at work, that suppresses
too much information; see Trac #9018.

So I'm trying out this rule: print explicit foralls if
  a) User specifies -fprint-explicit-foralls, or
  b) Any of the quantified type variables has a kind
     that mentions a kind variable

This catches common situations, such as a type siguature
     f :: m a
which means
      f :: forall k. forall (m :: k->*) (a :: k). m a
We really want to see both the "forall k" and the kind signatures
on m and a.  The latter comes from pprTvBndr.

Note [Infix type variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
With TypeOperators you can say

   f :: (a ~> b) -> b

and the (~>) is considered a type variable.  However, the type
pretty-printer in this module will just see (a ~> b) as

   App (App (TyVarTy "~>") (TyVarTy "a")) (TyVarTy "b")

So it'll print the type in prefix form.  To avoid confusion we must
remember to parenthesise the operator, thus

   (~>) a b -> b

See Trac #2766.
-}

pprTypeApp :: TyCon -> [Type] -> SDoc
pprTypeApp tc tys = pprTyTcApp TopPrec tc tys
        -- We have to use ppr on the TyCon (not its name)
        -- so that we get promotion quotes in the right place

pprTyTcApp :: TyPrec -> TyCon -> [Type] -> SDoc
-- Used for types only; so that we can make a
-- special case for type-level lists
pprTyTcApp p tc tys
  | tc `hasKey` ipTyConKey
  , [LitTy (StrTyLit n),ty] <- tys
  = maybeParen p FunPrec $
    char '?' <> ftext n <> ptext (sLit "::") <> ppr_type TopPrec ty

  | tc `hasKey` consDataConKey
  , [_kind,ty1,ty2] <- tys
  = sdocWithDynFlags $ \dflags ->
    if gopt Opt_PrintExplicitKinds dflags then pprTcApp  p ppr_type tc tys
                                   else pprTyList p ty1 ty2

  | tc `hasKey` tYPETyConKey
  , [TyConApp lev_tc []] <- tys
  = if lev_tc `hasKey` liftedDataConKey then char '*'
    else if lev_tc `hasKey` unliftedDataConKey then char '#'
         else pprPanic "pprTyTcApp unknown levity" (ppr lev_tc)

  | otherwise
  = pprTcApp p ppr_type tc tys

pprTcApp :: TyPrec -> (TyPrec -> a -> SDoc) -> TyCon -> [a] -> SDoc
-- Used for both types and coercions, hence polymorphism
pprTcApp _ pp tc [ty]
  | tc `hasKey` listTyConKey = pprPromotionQuote tc <> brackets   (pp TopPrec ty)
  | tc `hasKey` parrTyConKey = pprPromotionQuote tc <> paBrackets (pp TopPrec ty)

pprTcApp p pp tc tys
  | Just sort <- tyConTuple_maybe tc
  , let arity = tyConArity tc
  , arity == length tys
  , let num_to_drop = case sort of UnboxedTuple -> arity `div` 2
                                   _            -> 0
  = pprTupleApp p pp tc sort (drop num_to_drop tys)

  | Just dc <- isPromotedDataCon_maybe tc
  , let dc_tc = dataConTyCon dc
  , Just tup_sort <- tyConTuple_maybe dc_tc
  , let arity = tyConArity dc_tc    -- E.g. 3 for (,,) k1 k2 k3 t1 t2 t3
        ty_args = drop arity tys    -- Drop the kind args
  , ty_args `lengthIs` arity        -- Result is saturated
  = pprPromotionQuote tc <>
    (tupleParens tup_sort $ pprWithCommas (pp TopPrec) ty_args)

  | otherwise
  = sdocWithDynFlags (pprTcApp_help p pp tc tys)

pprTupleApp :: TyPrec -> (TyPrec -> a -> SDoc)
            -> TyCon -> TupleSort -> [a] -> SDoc
-- Print a saturated tuple
pprTupleApp p pp tc sort tys
  | null tys
  , ConstraintTuple <- sort
  = if opt_PprStyle_Debug then ptext (sLit "(%%)")
                          else maybeParen p FunPrec $
                               ptext (sLit "() :: Constraint")
  | otherwise
  = pprPromotionQuote tc <>
    tupleParens sort (pprWithCommas (pp TopPrec) tys)

pprTcApp_help :: TyPrec -> (TyPrec -> a -> SDoc) -> TyCon -> [a] -> DynFlags -> SDoc
-- This one has accss to the DynFlags
pprTcApp_help p pp tc tys dflags
  | not (isSymOcc (nameOccName (tyConName tc)))
  = pprPrefixApp p (ppr tc) (map (pp TyConPrec) tys_wo_kinds)

  | [ty1,ty2] <- tys_wo_kinds  -- Infix, two arguments;
                               -- we know nothing of precedence though
    -- TODO (RAE): Remove this hack to fix printing `GHC.Prim.~#`
  = let pp_tc | tc `hasKey` eqPrimTyConKey
              , not (gopt Opt_PrintExplicitKinds dflags)
              = text "~#"
              | otherwise
              = ppr tc
    in pprInfixApp p pp pp_tc ty1 ty2

  |  tc `hasKey` liftedTypeKindTyConKey
  || tc `hasKey` unliftedTypeKindTyConKey
  = ASSERT( null tys ) ppr tc   -- Do not wrap *, # in parens

  | otherwise
  = pprPrefixApp p (parens (ppr tc)) (map (pp TyConPrec) tys_wo_kinds)
  where
    tys_wo_kinds = suppressImplicits dflags (tyConKind tc) tys

------------------
-- | Given the kind of a 'TyCon', and the args to which it is applied,
-- suppress the args that are implicit
suppressImplicits :: DynFlags -> Kind -> [a] -> [a]
-- TODO (RAE): Rewrite in terms of partitionImplicits
suppressImplicits dflags kind xs
  | gopt Opt_PrintExplicitKinds dflags = xs
  | otherwise                          = suppress kind xs
  where
    suppress (ForAllTy bndr kind) (x : xs)
      | isInvisibleBinder bndr = suppress kind xs
      | otherwise              = x : suppress kind xs
    suppress _                          xs       = xs

----------------
pprTyList :: TyPrec -> Type -> Type -> SDoc
-- Given a type-level list (t1 ': t2), see if we can print
-- it in list notation [t1, ...].
pprTyList p ty1 ty2
  = case gather ty2 of
      (arg_tys, Nothing) -> char '\'' <> brackets (fsep (punctuate comma
                                            (map (ppr_type TopPrec) (ty1:arg_tys))))
      (arg_tys, Just tl) -> maybeParen p FunPrec $
                            hang (ppr_type FunPrec ty1)
                               2 (fsep [ colon <+> ppr_type FunPrec ty | ty <- arg_tys ++ [tl]])
  where
    gather :: Type -> ([Type], Maybe Type)
     -- (gather ty) = (tys, Nothing) means ty is a list [t1, .., tn]
     --             = (tys, Just tl) means ty is of form t1:t2:...tn:tl
    gather (TyConApp tc tys)
      | tc `hasKey` consDataConKey
      , [_kind, ty1,ty2] <- tys
      , (args, tl) <- gather ty2
      = (ty1:args, tl)
      | tc `hasKey` nilDataConKey
      = ([], Nothing)
    gather ty = ([], Just ty)

----------------
pprInfixApp :: TyPrec -> (TyPrec -> a -> SDoc) -> SDoc -> a -> a -> SDoc
pprInfixApp p pp pp_tc ty1 ty2
  = maybeParen p TyOpPrec $
    sep [pp TyOpPrec ty1, pprInfixVar True pp_tc <+> pp TyOpPrec ty2]

pprPrefixApp :: TyPrec -> SDoc -> [SDoc] -> SDoc
pprPrefixApp p pp_fun pp_tys
  | null pp_tys = pp_fun
  | otherwise   = maybeParen p TyConPrec $
                  hang pp_fun 2 (sep pp_tys)
----------------
pprArrowChain :: TyPrec -> [SDoc] -> SDoc
-- pprArrowChain p [a,b,c]  generates   a -> b -> c
pprArrowChain _ []         = empty
pprArrowChain p (arg:args) = maybeParen p FunPrec $
                             sep [arg, sep (map (arrow <+>) args)]

{-
%************************************************************************
%*                                                                      *
\subsection{TidyType}
%*                                                                      *
%************************************************************************
-}

-- | This tidies up a type for printing in an error message, or in
-- an interface file.
--
-- It doesn't change the uniques at all, just the print names.
tidyTyCoVarBndrs :: TidyEnv -> [TyCoVar] -> (TidyEnv, [TyCoVar])
tidyTyCoVarBndrs env tvs = mapAccumL tidyTyCoVarBndr env tvs

tidyTyCoVarBndr :: TidyEnv -> TyCoVar -> (TidyEnv, TyCoVar)
tidyTyCoVarBndr tidy_env@(occ_env, subst) tyvar
  = case tidyOccName occ_env occ1 of
      (tidy', occ') -> ((tidy', subst'), tyvar')
        where
          subst' = extendVarEnv subst tyvar tyvar'
          tyvar' = setTyVarKind (setTyVarName tyvar name') kind'
          name'  = tidyNameOcc name occ'
          kind'  = tidyKind tidy_env (tyVarKind tyvar)
  where
    name = tyVarName tyvar
    occ  = getOccName name
    -- System Names are for unification variables;
    -- when we tidy them we give them a trailing "0" (or 1 etc)
    -- so that they don't take precedence for the un-modified name
    -- Plus, indicating a unification variable in this way is a
    -- helpful clue for users
    occ1 | isSystemName name
         = if isTyVar tyvar
           then mkTyVarOcc (occNameString occ ++ "0")
           else mkVarOcc   (occNameString occ ++ "0")
         | otherwise         = occ

---------------
tidyFreeTyCoVars :: TidyEnv -> TyCoVarSet -> TidyEnv
-- ^ Add the free 'TyVar's to the env in tidy form,
-- so that we can tidy the type they are free in
tidyFreeTyCoVars (full_occ_env, var_env) tyvars
  = fst (tidyOpenTyCoVars (full_occ_env, var_env) (varSetElems tyvars))

        ---------------
tidyOpenTyCoVars :: TidyEnv -> [TyCoVar] -> (TidyEnv, [TyCoVar])
tidyOpenTyCoVars env tyvars = mapAccumL tidyOpenTyCoVar env tyvars

---------------
tidyOpenTyCoVar :: TidyEnv -> TyCoVar -> (TidyEnv, TyCoVar)
-- ^ Treat a new 'TyCoVar' as a binder, and give it a fresh tidy name
-- using the environment if one has not already been allocated. See
-- also 'tidyTyCoVarBndr'
tidyOpenTyCoVar env@(_, subst) tyvar
  = case lookupVarEnv subst tyvar of
        Just tyvar' -> (env, tyvar')              -- Already substituted
        Nothing     -> tidyTyCoVarBndr env tyvar  -- Treat it as a binder

---------------
tidyTyVarOcc :: TidyEnv -> TyVar -> TyVar
tidyTyVarOcc (_, subst) tv
  = case lookupVarEnv subst tv of
        Nothing  -> tv
        Just tv' -> tv'

---------------
tidyTypes :: TidyEnv -> [Type] -> [Type]
tidyTypes env tys = map (tidyType env) tys

---------------
tidyType :: TidyEnv -> Type -> Type
tidyType _   (LitTy n)            = LitTy n
tidyType env (TyVarTy tv)         = TyVarTy (tidyTyVarOcc env tv)
tidyType env (TyConApp tycon tys) = let args = tidyTypes env tys
                                    in args `seqList` TyConApp tycon args
tidyType env (AppTy fun arg)      = (AppTy $! (tidyType env fun)) $! (tidyType env arg)
tidyType env (ForAllTy (Anon fun) arg)
  = (ForAllTy $! (Anon $! (tidyType env fun))) $! (tidyType env arg)
tidyType env (ForAllTy (Named tv vis) ty)
  = (ForAllTy $! ((Named $! tvp) $! vis)) $! (tidyType envp ty)
  where
    (envp, tvp) = tidyTyCoVarBndr env tv
tidyType env (CastTy ty co)       = (CastTy $! tidyType env ty) $! (tidyCo env co)
tidyType env (CoercionTy co)      = CoercionTy $! (tidyCo env co)

---------------
-- | Grabs the free type variables, tidies them
-- and then uses 'tidyType' to work over the type itself
tidyOpenType :: TidyEnv -> Type -> (TidyEnv, Type)
tidyOpenType env ty
  = (env', tidyType (trimmed_occ_env, var_env) ty)
  where
    (env'@(_, var_env), tvs') = tidyOpenTyCoVars env (varSetElems (tyCoVarsOfType ty))
    trimmed_occ_env = initTidyOccEnv (map getOccName tvs')
      -- The idea here was that we restrict the new TidyEnv to the
      -- _free_ vars of the type, so that we don't gratuitously rename
      -- the _bound_ variables of the type.

---------------
tidyOpenTypes :: TidyEnv -> [Type] -> (TidyEnv, [Type])
tidyOpenTypes env tys = mapAccumL tidyOpenType env tys

---------------
-- | Calls 'tidyType' on a top-level type (i.e. with an empty tidying environment)
tidyTopType :: Type -> Type
tidyTopType ty = tidyType emptyTidyEnv ty

---------------
tidyOpenKind :: TidyEnv -> Kind -> (TidyEnv, Kind)
tidyOpenKind = tidyOpenType

tidyKind :: TidyEnv -> Kind -> Kind
tidyKind = tidyType

----------------
tidyCo :: TidyEnv -> Coercion -> Coercion
tidyCo env@(_, subst) co
  = go co
  where
    go (Refl r ty)           = Refl r (tidyType env ty)
    go (TyConAppCo r tc cos) = let args = map go cos
                               in args `seqList` TyConAppCo r tc args
    go (AppCo co1 co2)       = (AppCo $! go co1) $! go co2
    go (ForAllCo tv h co)    = ((ForAllCo $! tvp) $! (go h)) $! (tidyCo envp co)
                               where (envp, tvp) = tidyTyCoVarBndr env tv
            -- the case above duplicates a bit of work in tidying h and the kind
            -- of tv. But the alternative is to use coercionKind, which seems worse.
    go (CoVarCo cv)          = case lookupVarEnv subst cv of
                                 Nothing  -> CoVarCo cv
                                 Just cv' -> CoVarCo cv'
    go (AxiomInstCo con ind cos) = let args = map go cos
                               in  args `seqList` AxiomInstCo con ind args
    go (UnivCo p r t1 t2)    = (((UnivCo $! (go_prov p)) $! r) $!
                                tidyType env t1) $! tidyType env t2
    go (SymCo co)            = SymCo $! go co
    go (TransCo co1 co2)     = (TransCo $! go co1) $! go co2
    go (NthCo d co)          = NthCo d $! go co
    go (LRCo lr co)          = LRCo lr $! go co
    go (InstCo co ty)        = (InstCo $! go co) $! go ty
    go (CoherenceCo co1 co2) = (CoherenceCo $! go co1) $! go co2
    go (KindCo co)           = KindCo $! go co
    go (SubCo co)            = SubCo $! go co
    go (AxiomRuleCo ax cos)  = let cos1 = tidyCos env cos
                               in cos1 `seqList` AxiomRuleCo ax cos1

    go_prov UnsafeCoerceProv    = UnsafeCoerceProv
    go_prov (PhantomProv co)    = PhantomProv (go co)
    go_prov (ProofIrrelProv co) = ProofIrrelProv (go co)
    go_prov p@(PluginProv _)    = p
    go_prov p@(HoleProv _)      = p

tidyCos :: TidyEnv -> [Coercion] -> [Coercion]
tidyCos env = map (tidyCo env)
