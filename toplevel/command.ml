(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id$ *)

open Pp
open Util
open Options
open Term
open Termops
open Declarations
open Entries
open Inductive
open Environ
open Reduction
open Redexpr
open Declare
open Nametab
open Names
open Libnames
open Nameops
open Topconstr
open Library
open Libobject
open Constrintern
open Proof_type
open Tacmach
open Safe_typing
open Nametab
open Impargs
open Typeops
open Reductionops
open Indtypes
open Vernacexpr
open Decl_kinds
open Pretyping
open Pretyping.Default
open Notation

let mkLambdaCit = List.fold_right (fun (x,a) b -> mkLambdaC(x,a,b))
let mkProdCit = List.fold_right (fun (x,a) b -> mkProdC(x,a,b))

let rec abstract_constr_expr c = function
  | [] -> c
  | LocalRawDef (x,b)::bl -> mkLetInC(x,b,abstract_constr_expr c bl)
  | LocalRawAssum (idl,t)::bl ->
      List.fold_right (fun x b -> mkLambdaC([x],t,b)) idl
        (abstract_constr_expr c bl)

let rec generalize_constr_expr c = function
  | [] -> c
  | LocalRawDef (x,b)::bl -> mkLetInC(x,b,generalize_constr_expr c bl)
  | LocalRawAssum (idl,t)::bl ->
      List.fold_right (fun x b -> mkProdC([x],t,b)) idl
        (generalize_constr_expr c bl)

let rec under_binders env f n c =
  if n = 0 then f env Evd.empty c else
    match kind_of_term c with
      | Lambda (x,t,c) ->
	  mkLambda (x,t,under_binders (push_rel (x,None,t) env) f (n-1) c)
      | LetIn (x,b,t,c) ->
	  mkLetIn (x,b,t,under_binders (push_rel (x,Some b,t) env) f (n-1) c)
      | _ -> assert false

let rec destSubCast c = match kind_of_term c with
  | Lambda (x,t,c) -> 
      let (b,u) = destSubCast c in mkLambda (x,t,b), mkProd (x,t,u)
  | LetIn (x,b,t,c) ->
      let (d,u) = destSubCast c in mkLetIn (x,b,t,d), mkLetIn (x,b,t,u)
  | Cast (b,_, u) -> (b,u)
  | _ -> assert false

let rec complete_conclusion a cs = function
  | CProdN (loc,bl,c) -> CProdN (loc,bl,complete_conclusion a cs c)
  | CLetIn (loc,b,t,c) -> CLetIn (loc,b,t,complete_conclusion a cs c)
  | CHole loc ->
      let (has_no_args,name,params) = a in
      if not has_no_args then
	user_err_loc (loc,"",
	  str "Cannot infer the non constant arguments of the conclusion of "
	  ++ pr_id cs);
      let args = List.map (fun id -> CRef(Ident(loc,id))) params in
      CAppExpl (loc,(None,Ident(loc,name)),List.rev args)
  | c -> c

(* Commands of the interface *)

(* 1| Constant definitions *)

let definition_message id =
  if_verbose message ((string_of_id id) ^ " is defined")

let constant_entry_of_com (bl,com,comtypopt,opacity,boxed) =
  let sigma = Evd.empty in
  let env = Global.env() in
  match comtypopt with
      None -> 
	let b = abstract_constr_expr com bl in
	let j = interp_constr_judgment sigma env b in
	{ const_entry_body = j.uj_val;
	  const_entry_type = Some (refresh_universes j.uj_type);
          const_entry_opaque = opacity;
	  const_entry_boxed = boxed }
    | Some comtyp ->
	(* We use a cast to avoid troubles with evars in comtyp *)
	(* that can only be resolved knowing com *)
	let b = abstract_constr_expr (mkCastC (com, Rawterm.CastConv DEFAULTcast,comtyp)) bl in
	let (body,typ) = destSubCast (interp_constr sigma env b) in
	{ const_entry_body = body;
	  const_entry_type = Some typ;
          const_entry_opaque = opacity;
	  const_entry_boxed = boxed }

let red_constant_entry bl ce = function
  | None -> ce
  | Some red ->
      let body = ce.const_entry_body in
      { ce with const_entry_body = 
	under_binders (Global.env()) (fst (reduction_of_red_expr red))
	  (local_binders_length bl)
	  body }

let declare_global_definition ident ce local =
  let kn = declare_constant ident (DefinitionEntry ce,IsDefinition Definition) in
  if local = Local && Options.is_verbose() then
    msg_warning (pr_id ident ++ str" is declared as a global definition");
  definition_message ident;
  ConstRef kn

let declare_definition ident (local,boxed,dok) bl red_option c typopt hook =
  let ce = constant_entry_of_com (bl,c,typopt,false,boxed) in
  let ce' = red_constant_entry bl ce red_option in
  let r = match local with
    | Local when Lib.sections_are_opened () ->
        let c =
          SectionLocalDef(ce'.const_entry_body,ce'.const_entry_type,false) in
        let _ = declare_variable ident (Lib.cwd(),c,IsDefinition Definition) in
        definition_message ident;
        if Pfedit.refining () then 
          msgerrnl (str"Warning: Local definition " ++ pr_id ident ++ 
          str" is not visible from current goals");
        VarRef ident
    | (Global|Local) ->
        declare_global_definition ident ce' local in
  hook local r

let syntax_definition ident c local onlyparse =
  let c = snd (interp_aconstr [] [] c) in
  Syntax_def.declare_syntactic_definition local ident onlyparse c

(* 2| Variable/Hypothesis/Parameter/Axiom declarations *)

let assumption_message id =
  if_verbose message ((string_of_id id) ^ " is assumed")

let declare_one_assumption is_coe (local,kind) c (_,ident) =
  let r = match local with
    | Local when Lib.sections_are_opened () ->
        let _ = 
          declare_variable ident 
            (Lib.cwd(), SectionLocalAssum c, IsAssumption kind) in
        assumption_message ident;
        if is_verbose () & Pfedit.refining () then 
          msgerrnl (str"Warning: Variable " ++ pr_id ident ++ 
          str" is not visible from current goals");
        VarRef ident
    | (Global|Local) ->
        let kn =
          declare_constant ident (ParameterEntry c, IsAssumption kind) in
        assumption_message ident;
        if local=Local & Options.is_verbose () then
          msg_warning (pr_id ident ++ str" is declared as a parameter" ++
          str" because it is at a global level");
        ConstRef kn in
  if is_coe then Class.try_add_new_coercion r local

let declare_assumption idl is_coe k bl c =
  if not (Pfedit.refining ()) then 
    let c = generalize_constr_expr c bl in
    let c = interp_type Evd.empty (Global.env()) c in
      List.iter (declare_one_assumption is_coe k c) idl
  else
    errorlabstrm "Command.Assumption"
	(str "Cannot declare an assumption while in proof editing mode.")

(* 3a| Elimination schemes for mutual inductive definitions *)

open Indrec

let non_type_eliminations = 
  [ (InProp,elimination_suffix InProp);
    (InSet,elimination_suffix InSet) ]

let declare_one_elimination ind =
  let (mib,mip) = Global.lookup_inductive ind in 
  let mindstr = string_of_id mip.mind_typename in
  let declare s c t =
    let id = id_of_string s in
    let kn = Declare.declare_internal_constant id
      (DefinitionEntry
        { const_entry_body = c;
          const_entry_type = t;
          const_entry_opaque = false;
	  const_entry_boxed = Options.boxed_definitions() }, 
       Decl_kinds.IsDefinition Definition) in
    definition_message id;
    kn
  in
  let env = Global.env () in
  let sigma = Evd.empty in
  let elim_scheme = Indrec.build_indrec env sigma ind in
  let npars = mib.mind_nparams_rec in
  let make_elim s = Indrec.instantiate_indrec_scheme s npars elim_scheme in
  let kelim = elim_sorts (mib,mip) in
  (* in case the inductive has a type elimination, generates only one
     induction scheme, the other ones share the same code with the
     apropriate type *)
  if List.mem InType kelim then
    let elim = make_elim (new_sort_in_family InType) in
    let cte = declare (mindstr^(Indrec.elimination_suffix InType)) elim None in
    let c = mkConst cte and t = constant_type (Global.env()) cte in
    List.iter (fun (sort,suff) -> 
      let (t',c') = 
	Indrec.instantiate_type_indrec_scheme (new_sort_in_family sort)
	  npars c t in
      let _ = declare (mindstr^suff) c' (Some t') in ())
      non_type_eliminations
   else (* Impredicative or logical inductive definition *)
     List.iter
    (fun (sort,suff) -> 
       if List.mem sort kelim then
	 let elim = make_elim (new_sort_in_family sort) in
	 let _ = declare (mindstr^suff) elim None in ())
       non_type_eliminations

let declare_eliminations sp =
  let mib = Global.lookup_mind sp in
  if mib.mind_finite then
    for i = 0 to Array.length mib.mind_packets - 1 do
      declare_one_elimination (sp,i)
    done

(* 3b| Mutual inductive definitions *)

let compute_interning_datas env l nal typl =
  let mk_interning_data na typ =
    let idl, impl =
      if is_implicit_args() then
	let impl = compute_implicits env typ in
	let sub_impl,_ = list_chop (List.length l) impl in
	let sub_impl' = List.filter is_status_implicit sub_impl in
	(List.map name_of_implicit sub_impl', impl)
      else 
	([],[]) in
    (na, (idl, impl, compute_arguments_scope typ)) in
  (l, List.map2 mk_interning_data nal typl)

let declare_interning_data (_,impls) (df,c,scope) =
  silently (Metasyntax.add_notation_interpretation df impls c) scope

let push_named_types env idl tl =
  List.fold_left2 (fun env id t -> Environ.push_named (id,None,t) env)
    env idl tl

let push_types env idl tl =
  List.fold_left2 (fun env id t -> Environ.push_rel (Name id,None,t) env)
    env idl tl

type inductive_expr = {
  ind_name : identifier;
  ind_arity : constr_expr;
  ind_lc : (identifier * constr_expr) list
}

let minductive_message = function
  | []  -> error "no inductive definition"
  | [x] -> (pr_id x ++ str " is defined")
  | l   -> hov 0  (prlist_with_sep pr_coma pr_id l ++
		     spc () ++ str "are defined")

let check_all_names_different indl =
  let get_names ind = ind.ind_name::List.map fst ind.ind_lc in
  if not (list_distinct (List.flatten (List.map get_names indl))) then
    error "Two inductive objects have the same name"

let mk_mltype_data isevars env assums arity indname =
  let is_ml_type = is_sort env (Evd.evars_of !isevars) arity in
  (is_ml_type,indname,assums)

let prepare_param = function
  | (na,None,t) -> out_name na, LocalAssum t 
  | (na,Some b,_) -> out_name na, LocalDef b

let interp_ind_arity isevars env ind =
  interp_type_evars isevars env ind.ind_arity

let interp_cstrs isevars env impls mldata arity ind =
  let cnames,ctyps = List.split ind.ind_lc in
  (* Complete conclusions of constructor types if given in ML-style syntax *)
  let ctyps' = List.map2 (complete_conclusion mldata) cnames ctyps in
  (* Interpret the constructor types *)
  let ctyps'' = List.map (interp_type_evars isevars env ~impls) ctyps' in
  (cnames, ctyps'')

let interp_mutual paramsl indl notations finite = 
  check_all_names_different indl;
  let env0 = Global.env() in
  let isevars = ref (Evd.create_evar_defs Evd.empty) in
  let env_params, ctx_params = interp_context_evars isevars env0 paramsl in
  let indnames = List.map (fun ind -> ind.ind_name) indl in

  (* Names of parameters as arguments of the inductive type (defs removed) *)
  let assums = List.filter(fun (_,b,_) -> b=None) ctx_params in
  let params = List.map (fun (na,_,_) -> out_name na) assums in

  (* Interpret the arities *)
  let arities = List.map (interp_ind_arity isevars env_params) indl in
  let fullarities = List.map (fun c -> it_mkProd_or_LetIn c ctx_params) arities in
  let env_ar = push_types env0 indnames fullarities in
  let env_ar_params = push_rel_context ctx_params env_ar in

  (* Compute interpretation metadatas *)
  let impls = compute_interning_datas env0 params indnames fullarities in
  let mldatas = List.map2 (mk_mltype_data isevars env_params params) arities indnames in

  let constructors =
    States.with_heavy_rollback (fun () -> 
     (* Temporary declaration of notations and scopes *)
     List.iter (declare_interning_data impls) notations;
     (* Interpret the constructor types *)
     list_map3 (interp_cstrs isevars env_ar_params impls) mldatas arities indl)
     () in

  (* Instantiate evars and check all are resolved *)
  let sigma = Evd.evars_of !isevars in
  let ctx_params = Sign.map_rel_context (nf_evar sigma) ctx_params in
  let arities = List.map (nf_evar sigma) arities in
  List.iter (check_evars env_params Evd.empty isevars) arities;
  Sign.iter_rel_context (check_evars env0 Evd.empty isevars) ctx_params;
  List.iter (fun (_,ctyps) ->
    List.iter (check_evars env_ar_params Evd.empty isevars) ctyps)
    constructors;
  
  (* Build the inductive entries *)
  let entries = list_map3 (fun ind arity (cnames,ctypes) -> {
    mind_entry_typename = ind.ind_name;
    mind_entry_arity = arity;
    mind_entry_consnames = cnames;
    mind_entry_lc = ctypes
  }) indl arities constructors in

  (* Build the mutual inductive entry *)
  { mind_entry_params = List.map prepare_param ctx_params;
    mind_entry_record = false; 
    mind_entry_finite = finite; 
    mind_entry_inds = entries }

let eq_constr_expr c1 c2 =
  try let _ = Constrextern.check_same_type c1 c2 in true with _ -> false

(* Very syntactical equality *)
let eq_local_binder d1 d2 = match d1,d2 with
  | LocalRawAssum (nal1,c1), LocalRawAssum (nal2,c2) ->
      List.length nal1 = List.length nal2 &&
      List.for_all2 (fun (_,na1) (_,na2) -> na1 = na2) nal1 nal2 &&
      eq_constr_expr c1 c2
  | LocalRawDef ((_,id1),c1), LocalRawDef ((_,id2),c2) ->
      id1 = id2 && eq_constr_expr c1 c2
  | _ ->
      false

let eq_local_binders bl1 bl2 =
  List.length bl1 = List.length bl2 && List.for_all2 eq_local_binder bl1 bl2

let extract_coercions indl =
  let mkqid (_,((_,id),_)) = make_short_qualid id in
  let extract lc = List.filter (fun (iscoe,_) -> iscoe) lc in
  List.map mkqid (List.flatten(List.map (fun (_,_,_,lc) -> extract lc) indl))

let extract_params indl =
  let paramsl = List.map (fun (_,params,_,_) -> params) indl in
  match paramsl with
  | [] -> anomaly "empty list of inductive types"
  | params::paramsl ->
      if not (List.for_all (eq_local_binders params) paramsl) then error 
	"Parameters should be syntactically the same for each inductive type";
      params

let prepare_inductive ntnl indl =
  let indl =
    List.map (fun ((_,indname),_,ar,lc) -> { 
      ind_name = indname;
      ind_arity = ar;
      ind_lc = List.map (fun (_,((_,id),t)) -> (id,t)) lc
    }) indl in
  List.fold_right option_cons ntnl [], indl

let declare_mutual_with_eliminations isrecord mie =
  let names = List.map (fun e -> e.mind_entry_typename) mie.mind_entry_inds in
  let (_,kn) = declare_mind isrecord mie in
  if_verbose ppnl (minductive_message names);
  declare_eliminations kn;
  kn

let build_mutual l finite =
  let indl,ntnl = List.split l in
  let paramsl = extract_params indl in
  let coes = extract_coercions indl in
  let notations,indl = prepare_inductive ntnl indl in
  let mie = interp_mutual paramsl indl notations finite in
  (* Declare the mutual inductive block with its eliminations *)
  ignore (declare_mutual_with_eliminations false mie);
  (* Declare the possible notations of inductive types *)
  List.iter (declare_interning_data ([],[])) notations;
  (* Declare the coercions *)
  List.iter (fun qid -> Class.try_add_new_coercion (locate qid) Global) coes

(* 3c| Fixpoints and co-fixpoints *)

let recursive_message = function
  | [] -> anomaly "no recursive definition"
  | [id] -> pr_id id ++ str " is recursively defined"
  | l -> hov 0 (prlist_with_sep pr_coma pr_id l ++
		    spc () ++ str "are recursively defined")

let corecursive_message = function
  | [] -> error "no corecursive definition"
  | [id] -> pr_id id ++ str " is corecursively defined"
  | l -> hov 0 (prlist_with_sep pr_coma pr_id l ++
                    spc () ++ str "are corecursively defined")

let recursive_message isfix = 
  if isfix=Fixpoint then recursive_message else corecursive_message

(* An (unoptimized) function that maps preorders to partial orders...

   Input:  a list of associations (x,[y1;...;yn]), all yi distincts
           and different of x, meaning x<=y1, ..., x<=yn

   Output: a list of associations (x,Inr [y1;...;yn]), collecting all
           distincts yi greater than x, _or_, (x, Inl y) meaning that
           x is in the same class as y (in which case, x occurs
           nowhere else in the association map)

   partial_order : ('a * 'a list) list -> ('a * ('a,'a list) union) list
*)

let rec partial_order = function
  | [] -> []
  | (x,xge)::rest ->
    let rec browse res xge' = function
    | [] ->
	let res = List.map (function
	  | (z, Inr zge) when List.mem x zge -> (z, Inr (list_union zge xge'))
	  | r -> r) res in
	(x,Inr xge')::res
    | y::xge -> 
      let rec link y = 
	try match List.assoc y res with
	| Inl z -> link z
	| Inr yge -> 
	  if List.mem x yge then
	    let res = List.remove_assoc y res in
	    let res = List.map (function
	      | (z, Inl t) ->
		  if t = y then (z, Inl x) else (z, Inl t)
	      | (z, Inr zge) ->
		  if List.mem y zge then
		    (z, Inr (list_add_set x (list_remove y zge)))
		  else
		    (z, Inr zge)) res in
	    browse ((y,Inl x)::res) xge' (list_union xge (list_remove x yge))
	  else
	    browse res (list_add_set y (list_union xge' yge)) xge
	with Not_found -> browse res (list_add_set y xge') xge
      in link y
    in browse (partial_order rest) [] xge 

let check_mutuality env fixl =
  let names = List.map fst fixl in
  let preorder =
    List.map (fun (id,def) -> 
      (id, List.filter (fun id' -> id<>id' & occur_var env id' def) names))
      fixl in
  let po = partial_order preorder in
  match List.filter (function (_,Inr _) -> true | _ -> false) po with
    | (x,Inr xge)::(y,Inr yge)::_ ->
	if_verbose msg_warning 
	  (let reason = 
	    if List.mem x yge then 
	      string_of_id y^" depends on "^string_of_id x
	      ^" but not conversely"
	    else if List.mem y xge then 
	      string_of_id x^" depends on "^string_of_id y
	      ^" but not conversely"
	    else string_of_id y^" and "^string_of_id x
	  ^" are not mutually dependent" in
	  str ("Not a fully mutually defined fixpoint\n  (e.g.: "^reason^")"))
    | _ -> ()

type fixpoint_kind =
  | IsFixpoint of (int option * recursion_order_expr) list
  | IsCoFixpoint

type fixpoint_expr = {
  fix_name : identifier;
  fix_binders : local_binder list;
  fix_body : constr_expr;
  fix_type : constr_expr
}

let interp_fix_type isevars env fix =
  interp_type_evars isevars env 
    (generalize_constr_expr fix.fix_type fix.fix_binders)

let interp_fix_body isevars env impls fix fixtype =
  interp_casted_constr_evars isevars env ~impls
    (abstract_constr_expr fix.fix_body fix.fix_binders) fixtype

let declare_fix boxed kind f def t =
  let ce = {
    const_entry_body = def;
    const_entry_type = Some t;
    const_entry_opaque = false;
    const_entry_boxed = boxed
  } in
  let kn = declare_constant f (DefinitionEntry ce,IsDefinition kind) in
  ConstRef kn

let prepare_recursive_declaration fixnames fixtypes fixdefs =
  let defs = List.map (subst_vars (List.rev fixnames)) fixdefs in
  let names = List.map (fun id -> Name id) fixnames in
  (Array.of_list names, Array.of_list fixtypes, Array.of_list defs)

let compute_guardness_evidence (n,_) fixl fixtype =
  match n with 
  | Some n -> n 
  | None -> 
      (* Recursive argument was not given by the user : 
	 We check that there is only one inductive argument *)
      let m = local_binders_length fixl.fix_binders in
      let ctx = fst (Sign.decompose_prod_n_assum m fixtype) in
      let isIndApp t = isInd (fst (decompose_app (strip_head_cast t))) in 
      (* This could be more precise (e.g. do some delta) *)
      let lb = List.rev_map (fun (_,_,t) -> isIndApp t) ctx in
      try (list_unique_index true lb) - 1
      with Not_found -> error "the recursive argument needs to be specified"

let interp_recursive fixkind l boxed =
  let env = Global.env() in
  let fixl, ntnl = List.split l in
  let fixnames = List.map (fun fix -> fix.fix_name) fixl in

  (* Interp arities allowing for unresolved types *)
  let isevars = ref (Evd.create_evar_defs Evd.empty) in
  let fixtypes = List.map (interp_fix_type isevars env) fixl in
  let env_rec = push_named_types env fixnames fixtypes in

  (* Get interpretation metadatas *)
  let impls = compute_interning_datas env [] fixnames fixtypes in
  let notations = List.fold_right option_cons ntnl [] in

  (* Interp bodies with rollback because temp use of notations/implicit *)
  let fixdefs = 
    States.with_heavy_rollback (fun () -> 
      List.iter (declare_interning_data impls) notations;
      List.map2 (interp_fix_body isevars env_rec impls) fixl fixtypes)
      () in

  (* Instantiate evars and check all are resolved *)
  let fixtypes = List.map (nf_evar (Evd.evars_of !isevars)) fixtypes in
  List.iter (check_evars env_rec Evd.empty isevars) fixdefs;
  check_mutuality env (List.combine fixnames fixdefs);

  (* Build the fix declaration block *)
  let fixdecls = prepare_recursive_declaration fixnames fixtypes fixdefs in
  let fixdecls = 
    match fixkind with
    | IsFixpoint wfl ->
	let fixwf = list_map3 compute_guardness_evidence wfl fixl fixtypes in
	list_map_i (fun i _ -> mkFix ((Array.of_list fixwf,i),fixdecls)) 0 l
    | IsCoFixpoint ->
	list_map_i (fun i _ -> mkCoFix (i,fixdecls)) 0 l
  in

  (* Declare the recursive definitions *)
  let kind = if fixkind <> IsCoFixpoint then Fixpoint else CoFixpoint in
  ignore (list_map3 (declare_fix boxed kind) fixnames fixdecls fixtypes);
  if_verbose ppnl (recursive_message kind fixnames);

  (* Declare notations *)
  List.iter (declare_interning_data ([],[])) notations

let build_recursive l b =
  let g = List.map (fun ((_,wf,_,_,_),_) -> wf) l in
  let fixl = List.map (fun ((id,_,bl,typ,def),ntn) -> 
    ({fix_name = id; fix_binders = bl; fix_body = def; fix_type = typ},ntn))
    l in
  interp_recursive (IsFixpoint g) fixl b

let build_corecursive l b =
  let fixl = List.map (fun ((id,bl,typ,def),ntn) -> 
    ({fix_name = id; fix_binders = bl; fix_body = def; fix_type = typ},ntn))
    l in
  interp_recursive IsCoFixpoint fixl b

(* 3d| Schemes *)

let build_scheme lnamedepindsort = 
  let lrecnames = List.map (fun ((_,f),_,_,_) -> f) lnamedepindsort
  and sigma = Evd.empty
  and env0 = Global.env() in
  let lrecspec =
    List.map
      (fun (_,dep,indid,sort) ->
        let ind = Nametab.global_inductive indid in
        let (mib,mip) = Global.lookup_inductive ind in
         (ind,mib,mip,dep,interp_elimination_sort sort)) 
      lnamedepindsort
  in
  let listdecl = Indrec.build_mutual_indrec env0 sigma lrecspec in 
  let rec declare decl fi lrecref =
    let decltype = Retyping.get_type_of env0 Evd.empty decl in
    let decltype = refresh_universes decltype in
    let ce = { const_entry_body = decl;
               const_entry_type = Some decltype;
               const_entry_opaque = false;
	       const_entry_boxed = Options.boxed_definitions() } in
    let kn = declare_constant fi (DefinitionEntry ce, IsDefinition Scheme) in
    ConstRef kn :: lrecref
  in 
  let _ = List.fold_right2 declare listdecl lrecnames [] in
  if_verbose ppnl (recursive_message Fixpoint lrecnames)

(* 4| Goal declaration *)

let start_proof id kind c hook =
  let sign = Global.named_context () in
  let sign = clear_proofs sign in
  Pfedit.start_proof id kind sign c hook

let start_proof_com sopt kind (bl,t) hook =
  let id = match sopt with
    | Some id ->
        (* We check existence here: it's a bit late at Qed time *)
        if Nametab.exists_cci (Lib.make_path id) or is_section_variable id then
          errorlabstrm "start_proof" (pr_id id ++ str " already exists");
        id
    | None ->
	next_global_ident_away false (id_of_string "Unnamed_thm")
 	  (Pfedit.get_all_proof_names ())
  in
  let env = Global.env () in
  let c = interp_type Evd.empty env (generalize_constr_expr t bl) in
  let _ = Typeops.infer_type env c in
  start_proof id kind c hook

let save id const (locality,kind) hook =
  let {const_entry_body = pft;
       const_entry_type = tpo;
       const_entry_opaque = opacity } = const in
  let l,r = match locality with
    | Local when Lib.sections_are_opened () ->
        let k = logical_kind_of_goal_kind kind in
	let c = SectionLocalDef (pft, tpo, opacity) in
	let _ = declare_variable id (Lib.cwd(), c, k) in
	(Local, VarRef id)
    | Local ->
        let k = logical_kind_of_goal_kind kind in
        let kn = declare_constant id (DefinitionEntry const, k) in
	(Global, ConstRef kn)
    | Global ->
        let k = logical_kind_of_goal_kind kind in
        let kn = declare_constant id (DefinitionEntry const, k) in
	(Global, ConstRef kn) in
  Pfedit.delete_current_proof ();
  hook l r;
  definition_message id

let save_named opacity =
  let id,(const,persistence,hook) = Pfedit.cook_proof () in
  let const = { const with const_entry_opaque = opacity } in
  save id const persistence hook

let check_anonymity id save_ident =
  if atompart_of_id id <> "Unnamed_thm" then
    error "This command can only be used for unnamed theorem"
(*
    message("Overriding name "^(string_of_id id)^" and using "^save_ident)
*)

let save_anonymous opacity save_ident =
  let id,(const,persistence,hook) = Pfedit.cook_proof () in
  let const = { const with const_entry_opaque = opacity } in
  check_anonymity id save_ident;
  save save_ident const persistence hook

let save_anonymous_with_strength kind opacity save_ident =
  let id,(const,_,hook) = Pfedit.cook_proof () in
  let const = { const with const_entry_opaque = opacity } in
  check_anonymity id save_ident;
  (* we consider that non opaque behaves as local for discharge *)
  save save_ident const (Global, Proof kind) hook

let admit () =
  let (id,k,typ,hook) = Pfedit.current_proof_statement () in
(* Contraire aux besoins d'interactivité...
  if k <> IsGlobal (Proof Conjecture) then
    error "Only statements declared as conjecture can be admitted";
*)
  let kn =
    declare_constant id (ParameterEntry typ, IsAssumption Conjectural) in
  Pfedit.delete_current_proof ();
  hook Global (ConstRef kn);
  assumption_message id

let get_current_context () =
  try Pfedit.get_current_goal_context ()
  with e when Logic.catchable_exception e -> 
    (Evd.empty, Global.env())
