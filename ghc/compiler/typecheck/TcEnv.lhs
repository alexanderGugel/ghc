\begin{code}
module TcEnv(
	TyThing(..), TyThingDetails(..), TcTyThing(..), TcId,

	-- Instance environment, and InstInfo type
	tcGetInstEnv, tcSetInstEnv, 
	InstInfo(..), pprInstInfo, pprInstInfoDetails,
	simpleInstInfoTy, simpleInstInfoTyCon, 
	InstBindings(..),

	-- Global environment
	tcExtendGlobalEnv, 
	tcExtendGlobalValEnv,
	tcExtendGlobalTypeEnv,
	tcLookupTyCon, tcLookupClass, tcLookupDataCon,
	tcLookupGlobal_maybe, tcLookupGlobal, tcLookupGlobalId,
	getInGlobalScope,

	-- Local environment
	tcExtendKindEnv,     
	tcExtendTyVarEnv,    tcExtendTyVarEnv2, 
	tcExtendLocalValEnv, tcExtendLocalValEnv2, 
	tcLookup, tcLookupLocalIds, tcLookup_maybe, 
	tcLookupId, tcLookupIdLvl, 
	getLclEnvElts, getInLocalScope,

	-- Instance environment
	tcExtendLocalInstEnv, tcExtendInstEnv, 

	-- Rules
 	tcExtendRules,

	-- Global type variables
	tcGetGlobalTyVars,

	-- Random useful things
	RecTcGblEnv, tcLookupRecId_maybe, 

	-- Template Haskell stuff
	wellStaged, spliceOK, bracketOK, tcMetaTy, metaLevel,

	-- New Ids
	newLocalName, newDFunName,

	-- Misc
	isLocalThing
  ) where

#include "HsVersions.h"

import RnHsSyn		( RenamedMonoBinds, RenamedSig )
import HsSyn		( RuleDecl(..), ifaceRuleDeclName )
import TcRnMonad
import TcMType		( zonkTcTyVarsAndFV )
import TcType		( Type, ThetaType, TcKind, TcTyVar, TcTyVarSet, 
			  tyVarsOfTypes, tcSplitDFunTy, mkGenTyConApp,
			  getDFunTyKey, tcTyConAppTyCon, 
			)
import Rules		( extendRuleBase )
import Id		( idName, isDataConWrapId_maybe )
import Var		( TyVar, Id, idType )
import VarSet
import CoreSyn		( IdCoreRule )
import DataCon		( DataCon )
import TyCon		( TyCon, DataConDetails )
import Class		( Class, ClassOpItem )
import Name		( Name, NamedThing(..), 
			  getSrcLoc, mkInternalName, nameIsLocalOrFrom
			)
import NameEnv
import OccName		( mkDFunOcc, occNameString )
import HscTypes		( DFunId, TypeEnv, extendTypeEnvList, 
			  TyThing(..), ExternalPackageState(..) )
import Rules		( RuleBase )
import BasicTypes	( EP )
import Module		( Module )
import InstEnv		( InstEnv, extendInstEnv )
import Maybes		( seqMaybe )
import SrcLoc		( SrcLoc )
import Outputable
import Maybe		( isJust )
import List		( partition )
\end{code}


%************************************************************************
%*									*
		Meta level
%*									*
%************************************************************************

\begin{code}
instance Outputable Stage where
   ppr Comp	     = text "Comp"
   ppr (Brack l _ _) = text "Brack" <+> int l
   ppr (Splice l)    = text "Splice" <+> int l


metaLevel :: Stage -> Level
metaLevel Comp	        = topLevel
metaLevel (Splice l)    = l
metaLevel (Brack l _ _) = l

wellStaged :: Level 	-- Binding level
	   -> Level	-- Use level
	   -> Bool
wellStaged bind_stage use_stage 
  = bind_stage <= use_stage

-- Indicates the legal transitions on bracket( [| |] ).
bracketOK :: Stage -> Maybe Level
bracketOK (Brack _ _ _) = Nothing	-- Bracket illegal inside a bracket
bracketOK stage         = (Just (metaLevel stage + 1))

-- Indicates the legal transitions on splice($).
spliceOK :: Stage -> Maybe Level
spliceOK (Splice _) = Nothing	-- Splice illegal inside splice
spliceOK stage      = Just (metaLevel stage - 1)

tcMetaTy :: Name -> TcM Type
-- Given the name of a Template Haskell data type, 
-- return the type
-- E.g. given the name "Expr" return the type "Expr"
tcMetaTy tc_name
  = tcLookupTyCon tc_name	`thenM` \ t ->
    returnM (mkGenTyConApp t [])
	-- Use mkGenTyConApp because it might be a synonym
\end{code}


%************************************************************************
%*									*
\subsection{TyThingDetails}
%*									*
%************************************************************************

This data type is used to help tie the knot
 when type checking type and class declarations

\begin{code}
data TyThingDetails = SynTyDetails  Type
		    | DataTyDetails ThetaType (DataConDetails DataCon) [Id] (Maybe (EP Id))
		    | ClassDetails  ThetaType [Id] [ClassOpItem] DataCon Name
				-- The Name is the Name of the implicit TyCon for the class
		    | ForeignTyDetails	-- Nothing yet
\end{code}


%************************************************************************
%*									*
\subsection{Basic lookups}
%*									*
%************************************************************************

\begin{code}
type RecTcGblEnv = TcGblEnv
-- This environment is used for getting the 'right' IdInfo 
-- on imported things and for looking up Ids in unfoldings
-- The environment doesn't have any local Ids in it

tcLookupRecId_maybe :: RecTcGblEnv -> Name -> Maybe Id
tcLookupRecId_maybe env name = case lookup_global env name of
				   Just (AnId id) -> Just id
				   other	  -> Nothing
\end{code}

%************************************************************************
%*									*
\subsection{Making new Ids}
%*									*
%************************************************************************

Constructing new Ids

\begin{code}
newLocalName :: Name -> TcM Name
newLocalName name	-- Make a clone
  = newUnique		`thenM` \ uniq ->
    returnM (mkInternalName uniq (getOccName name) (getSrcLoc name))
\end{code}

Make a name for the dict fun for an instance decl.
It's a *local* name for the moment.  The CoreTidy pass
will externalise it.

\begin{code}
newDFunName :: Class -> [Type] -> SrcLoc -> TcM Name
newDFunName clas (ty:_) loc
  = newUnique			`thenM` \ uniq ->
    returnM (mkInternalName uniq (mkDFunOcc dfun_string) loc)
  where
	-- Any string that is somewhat unique will do
    dfun_string = occNameString (getOccName clas) ++ occNameString (getDFunTyKey ty)

newDFunName clas [] loc = pprPanic "newDFunName" (ppr clas <+> ppr loc)
\end{code}

\begin{code}
isLocalThing :: NamedThing a => Module -> a -> Bool
isLocalThing mod thing = nameIsLocalOrFrom mod (getName thing)
\end{code}

%************************************************************************
%*									*
\subsection{The global environment}
%*									*
%************************************************************************

\begin{code}
tcExtendGlobalEnv :: [TyThing] -> TcM r -> TcM r
  -- Given a mixture of Ids, TyCons, Classes, perhaps from the
  -- module being compiled, perhaps from a package module,
  -- extend the global environment, and update the EPS
tcExtendGlobalEnv things thing_inside
   = do	{ eps <- getEps
	; hpt <- getHpt
	; env <- getGblEnv
	; let mod = tcg_mod env
	      (lcl_things, pkg_things) = partition (isLocalThing mod) things
	      ge'  = extendTypeEnvList (tcg_type_env env) lcl_things
	      eps' = eps { eps_PTE = extendTypeEnvList (eps_PTE eps) pkg_things }
	      ist' = mkImpTypeEnv eps' hpt
	; setEps eps'
	; setGblEnv (env {tcg_type_env = ge', tcg_ist = ist'}) thing_inside }

tcExtendGlobalValEnv :: [Id] -> TcM a -> TcM a
  -- Same deal as tcExtendGlobalEnv, but for Ids
tcExtendGlobalValEnv ids thing_inside 
  = tcExtendGlobalEnv [AnId id | id <- ids] thing_inside

tcExtendGlobalTypeEnv :: TypeEnv -> TcM r -> TcM r
  -- Top-level things of the interactive context
  -- No need to extend the package env
tcExtendGlobalTypeEnv extra_env thing_inside
 = do { env <- getGblEnv 
      ; let ge' = tcg_type_env env `plusNameEnv` extra_env 
      ; setGblEnv (env {tcg_type_env = ge'}) thing_inside }
\end{code}


\begin{code}
lookup_global :: TcGblEnv -> Name -> Maybe TyThing
	-- Try the global envt and then the global symbol table
lookup_global env name 
  = lookupNameEnv (tcg_type_env env) name 
    	`seqMaybe`
    tcg_ist env name

tcLookupGlobal_maybe :: Name -> TcRn m (Maybe TyThing)
tcLookupGlobal_maybe name
  = getGblEnv		`thenM` \ env ->
    returnM (lookup_global env name)
\end{code}

A variety of global lookups, when we know what we are looking for.

\begin{code}
tcLookupGlobal :: Name -> TcM TyThing
tcLookupGlobal name
  = tcLookupGlobal_maybe name	`thenM` \ maybe_thing ->
    case maybe_thing of
	Just thing -> returnM thing
	other	   -> notFound "tcLookupGlobal" name

tcLookupGlobalId :: Name -> TcM Id
tcLookupGlobalId name
  = tcLookupGlobal_maybe name	`thenM` \ maybe_thing ->
    case maybe_thing of
	Just (AnId id) -> returnM id
	other	       -> notFound "tcLookupGlobal" name

tcLookupDataCon :: Name -> TcM DataCon
tcLookupDataCon con_name
  = tcLookupGlobalId con_name	`thenM` \ con_id ->
    case isDataConWrapId_maybe con_id of
	Just data_con -> returnM data_con
	Nothing	      -> failWithTc (badCon con_id)

tcLookupClass :: Name -> TcM Class
tcLookupClass name
  = tcLookupGlobal_maybe name	`thenM` \ maybe_clas ->
    case maybe_clas of
	Just (AClass clas) -> returnM clas
	other		   -> notFound "tcLookupClass" name
	
tcLookupTyCon :: Name -> TcM TyCon
tcLookupTyCon name
  = tcLookupGlobal_maybe name	`thenM` \ maybe_tc ->
    case maybe_tc of
	Just (ATyCon tc) -> returnM tc
	other		 -> notFound "tcLookupTyCon" name


getInGlobalScope :: TcRn m (Name -> Bool)
getInGlobalScope = do { gbl_env <- getGblEnv ;
		        return (\n -> isJust (lookup_global gbl_env n)) }
\end{code}


%************************************************************************
%*									*
\subsection{The local environment}
%*									*
%************************************************************************

\begin{code}
tcLookup_maybe :: Name -> TcM (Maybe TcTyThing)
tcLookup_maybe name
  = getLclEnv 		`thenM` \ local_env ->
    case lookupNameEnv (tcl_env local_env) name of
	Just thing -> returnM (Just thing)
	Nothing    -> tcLookupGlobal_maybe name `thenM` \ mb_res ->
		      returnM (case mb_res of
				 Just thing -> Just (AGlobal thing)
				 Nothing    -> Nothing)

tcLookup :: Name -> TcM TcTyThing
tcLookup name
  = tcLookup_maybe name		`thenM` \ maybe_thing ->
    case maybe_thing of
	Just thing -> returnM thing
	other	   -> notFound "tcLookup" name
	-- Extract the IdInfo from an IfaceSig imported from an interface file

tcLookupId :: Name -> TcM Id
-- Used when we aren't interested in the binding level
tcLookupId name
  = tcLookup name	`thenM` \ thing -> 
    case thing of
	ATcId tc_id lvl	  -> returnM tc_id
	AGlobal (AnId id) -> returnM id
	other		  -> pprPanic "tcLookupId" (ppr name)

tcLookupIdLvl :: Name -> TcM (Id, Level)
tcLookupIdLvl name
  = tcLookup name	`thenM` \ thing -> 
    case thing of
	ATcId tc_id lvl	  -> returnM (tc_id, lvl)
	AGlobal (AnId id) -> returnM (id, impLevel)
	other		  -> pprPanic "tcLookupIdLvl" (ppr name)

tcLookupLocalIds :: [Name] -> TcM [TcId]
-- We expect the variables to all be bound, and all at
-- the same level as the lookup.  Only used in one place...
tcLookupLocalIds ns
  = getLclEnv 		`thenM` \ env ->
    returnM (map (lookup (tcl_env env) (metaLevel (tcl_level env))) ns)
  where
    lookup lenv lvl name 
	= case lookupNameEnv lenv name of
		Just (ATcId id lvl1) -> ASSERT( lvl == lvl1 ) id
		other		     -> pprPanic "tcLookupLocalIds" (ppr name)

getLclEnvElts :: TcM [TcTyThing]
getLclEnvElts = getLclEnv	`thenM` \ env ->
		return (nameEnvElts (tcl_env env))

getInLocalScope :: TcM (Name -> Bool)
  -- Ids only
getInLocalScope = getLclEnv	`thenM` \ env ->
		  let 
			lcl_env = tcl_env env
		  in
		  return (`elemNameEnv` lcl_env)
\end{code}

\begin{code}
tcExtendKindEnv :: [(Name,TcKind)] -> TcM r -> TcM r
tcExtendKindEnv pairs thing_inside
  = updLclEnv upd thing_inside
  where
    upd lcl_env = lcl_env { tcl_env = extend (tcl_env lcl_env) }
    extend env = extendNameEnvList env [(n, AThing k) | (n,k) <- pairs]
	-- No need to extend global tyvars for kind checking
    
tcExtendTyVarEnv :: [TyVar] -> TcM r -> TcM r
tcExtendTyVarEnv tvs thing_inside
  = tc_extend_tv_env [(getName tv, ATyVar tv) | tv <- tvs] tvs thing_inside

tcExtendTyVarEnv2 :: [(TyVar,TcTyVar)] -> TcM r -> TcM r
tcExtendTyVarEnv2 tv_pairs thing_inside
  = tc_extend_tv_env [(getName tv1, ATyVar tv2) | (tv1,tv2) <- tv_pairs]
		     [tv | (_,tv) <- tv_pairs]
		     thing_inside

tc_extend_tv_env binds tyvars thing_inside
  = getLclEnv	   `thenM` \ env@(TcLclEnv {tcl_env = le, tcl_tyvars = gtvs}) ->
    let
 	le'        = extendNameEnvList le binds
	new_tv_set = mkVarSet tyvars
    in
	-- It's important to add the in-scope tyvars to the global tyvar set
	-- as well.  Consider
	--	f (x::r) = let g y = y::r in ...
	-- Here, g mustn't be generalised.  This is also important during
	-- class and instance decls, when we mustn't generalise the class tyvars
	-- when typechecking the methods.
    tc_extend_gtvs gtvs new_tv_set		`thenM` \ gtvs' ->
    setLclEnv (env {tcl_env = le', tcl_tyvars = gtvs'}) thing_inside
\end{code}


\begin{code}
tcExtendLocalValEnv :: [TcId] -> TcM a -> TcM a
tcExtendLocalValEnv ids thing_inside
  = getLclEnv		`thenM` \ env ->
    let
	extra_global_tyvars = tyVarsOfTypes [idType id | id <- ids]
	lvl		    = metaLevel (tcl_level env)
	extra_env	    = [(idName id, ATcId id lvl) | id <- ids]
	le'		    = extendNameEnvList (tcl_env env) extra_env
    in
    tc_extend_gtvs (tcl_tyvars env) extra_global_tyvars	`thenM` \ gtvs' ->
    setLclEnv (env {tcl_env = le', tcl_tyvars = gtvs'}) thing_inside

tcExtendLocalValEnv2 :: [(Name,TcId)] -> TcM a -> TcM a
tcExtendLocalValEnv2 names_w_ids thing_inside
  = getLclEnv		`thenM` \ env ->
    let
	extra_global_tyvars = tyVarsOfTypes [idType id | (name,id) <- names_w_ids]
	lvl		    = metaLevel (tcl_level env)
	extra_env	    = [(name, ATcId id lvl) | (name,id) <- names_w_ids]
	le'		    = extendNameEnvList (tcl_env env) extra_env
    in
    tc_extend_gtvs (tcl_tyvars env) extra_global_tyvars	`thenM` \ gtvs' ->
    setLclEnv (env {tcl_env = le', tcl_tyvars = gtvs'}) thing_inside
\end{code}


%************************************************************************
%*									*
\subsection{The global tyvars}
%*									*
%************************************************************************

\begin{code}
tc_extend_gtvs gtvs extra_global_tvs
  = readMutVar gtvs		`thenM` \ global_tvs ->
    newMutVar (global_tvs `unionVarSet` extra_global_tvs)
\end{code}

@tcGetGlobalTyVars@ returns a fully-zonked set of tyvars free in the environment.
To improve subsequent calls to the same function it writes the zonked set back into
the environment.

\begin{code}
tcGetGlobalTyVars :: TcM TcTyVarSet
tcGetGlobalTyVars
  = getLclEnv					`thenM` \ (TcLclEnv {tcl_tyvars = gtv_var}) ->
    readMutVar gtv_var				`thenM` \ gbl_tvs ->
    zonkTcTyVarsAndFV (varSetElems gbl_tvs)	`thenM` \ gbl_tvs' ->
    writeMutVar gtv_var gbl_tvs'		`thenM_` 
    returnM gbl_tvs'
\end{code}


%************************************************************************
%*									*
\subsection{The instance environment}
%*									*
%************************************************************************

\begin{code}
tcGetInstEnv :: TcM InstEnv
tcGetInstEnv = getGblEnv 	`thenM` \ env -> 
	       returnM (tcg_inst_env env)

tcSetInstEnv :: InstEnv -> TcM a -> TcM a
tcSetInstEnv ie thing_inside
  = getGblEnv 	`thenM` \ env ->
    setGblEnv (env {tcg_inst_env = ie}) thing_inside

tcExtendInstEnv :: [DFunId] -> TcM a -> TcM a
	-- Add instances from local or imported
	-- instances, and refresh the instance-env cache
tcExtendInstEnv dfuns thing_inside
 = do { dflags <- getDOpts
      ; eps <- getEps
      ; env <- getGblEnv
      ; let
	  -- Extend the total inst-env with the new dfuns
	  (inst_env', errs) = extendInstEnv dflags (tcg_inst_env env) dfuns
  
	  -- Sort the ones from this module from the others
	  (lcl_dfuns, pkg_dfuns) = partition (isLocalThing mod) dfuns
	  mod = tcg_mod env
  
	  -- And add the pieces to the right places
       	  (eps_inst_env', _) = extendInstEnv dflags (eps_inst_env eps) pkg_dfuns
	  eps'		     = eps { eps_inst_env = eps_inst_env' }
  
	  env'	= env { tcg_inst_env = inst_env', 
			tcg_insts = lcl_dfuns ++ tcg_insts env }

      ; traceDFuns dfuns
      ; addErrs errs
      ; setEps eps'
      ; setGblEnv env' thing_inside }

tcExtendLocalInstEnv :: [InstInfo] -> TcM a -> TcM a
  -- Special case for local instance decls
tcExtendLocalInstEnv infos thing_inside
 = do { dflags <- getDOpts
      ; env <- getGblEnv
      ; let
	  dfuns 	    = map iDFunId infos
	  (inst_env', errs) = extendInstEnv dflags (tcg_inst_env env) dfuns
	  env'		    = env { tcg_inst_env = inst_env', 
			            tcg_insts = dfuns ++ tcg_insts env }
      ; traceDFuns dfuns
      ; addErrs errs
      ; setGblEnv env' thing_inside }

traceDFuns dfuns
  = traceTc (text "Adding instances:" <+> vcat (map pp dfuns))
  where
    pp dfun   = ppr dfun <+> dcolon <+> ppr (idType dfun)
\end{code}


%************************************************************************
%*									*
\subsection{Rules}
%*									*
%************************************************************************

\begin{code}
tcExtendRules :: [RuleDecl Id] -> TcM a -> TcM a
	-- Just pop the new rules into the EPS and envt resp
	-- All the rules come from an interface file, not soruce
	-- Nevertheless, some may be for this module, if we read
	-- its interface instead of its source code
tcExtendRules rules thing_inside
 = do { eps <- getEps
      ; env <- getGblEnv
      ; let
	  (lcl_rules, pkg_rules) = partition is_local_rule rules
	  is_local_rule = isLocalThing mod . ifaceRuleDeclName
	  mod = tcg_mod env

	  core_rules = [(id,rule) | IfaceRuleOut id rule <- pkg_rules]
	  eps'   = eps { eps_rule_base = addIfaceRules (eps_rule_base eps) core_rules }
		  -- All the rules from an interface are of the IfaceRuleOut form

	  env' = env { tcg_rules = lcl_rules ++ tcg_rules env }

      ; setEps eps' 
      ; setGblEnv env' thing_inside }

addIfaceRules :: RuleBase -> [IdCoreRule] -> RuleBase
addIfaceRules rule_base rules
  = foldl extendRuleBase rule_base rules
\end{code}


%************************************************************************
%*									*
\subsection{The InstInfo type}
%*									*
%************************************************************************

The InstInfo type summarises the information in an instance declaration

    instance c => k (t tvs) where b

It is used just for *local* instance decls (not ones from interface files).
But local instance decls includes
	- derived ones
	- generic ones
as well as explicit user written ones.

\begin{code}
data InstInfo
  = InstInfo {
      iDFunId :: DFunId,		-- The dfun id
      iBinds  :: InstBindings
    }

data InstBindings
  = VanillaInst 		-- The normal case
	RenamedMonoBinds	-- Bindings
      	[RenamedSig]		-- User pragmas recorded for generating 
				-- specialised instances

  | NewTypeDerived 		-- Used for deriving instances of newtypes, where the
	[Type]			-- witness dictionary is identical to the argument 
				-- dictionary.  Hence no bindings, no pragmas
	-- The [Type] are the representation types
	-- See notes in TcDeriv

pprInstInfo info = vcat [ptext SLIT("InstInfo:") <+> ppr (idType (iDFunId info))]

pprInstInfoDetails (InstInfo { iBinds = VanillaInst b _ }) = ppr b
pprInstInfoDetails (InstInfo { iBinds = NewTypeDerived _}) = text "Derived from the represenation type"

simpleInstInfoTy :: InstInfo -> Type
simpleInstInfoTy info = case tcSplitDFunTy (idType (iDFunId info)) of
			  (_, _, _, [ty]) -> ty

simpleInstInfoTyCon :: InstInfo -> TyCon
  -- Gets the type constructor for a simple instance declaration,
  -- i.e. one of the form 	instance (...) => C (T a b c) where ...
simpleInstInfoTyCon inst = tcTyConAppTyCon (simpleInstInfoTy inst)
\end{code}


%************************************************************************
%*									*
\subsection{Errors}
%*									*
%************************************************************************

\begin{code}
badCon con_id = quotes (ppr con_id) <+> ptext SLIT("is not a data constructor")

notFound wheRe name = failWithTc (text wheRe <> colon <+> quotes (ppr name) <+> 
				  ptext SLIT("is not in scope"))
\end{code}
