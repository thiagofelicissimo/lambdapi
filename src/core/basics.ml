(** Basic operations on terms. *)

open Extra
open Timed
open Terms

(** Sets and maps of variables. *)
module Var =
  struct
    type t = term Bindlib.var
    let compare = Bindlib.compare_vars
  end

module VarSet = Set.Make(Var)
module VarMap = Map.Make(Var)

(** [to_tvar t] returns [x] if [t] is of the form [Vari x] and fails
    otherwise. *)
let to_tvar : term -> tvar = fun t ->
  match t with Vari(x) -> x | _ -> assert false

(** {b NOTE} the {!val:Array.map to_tvar} function is useful when working
   with multiple binders. For example, this is the case when manipulating
   pattern variables ([Patt] constructor) or metatavariables ([Meta]
   constructor).  Remark that it is important for these constructors to hold
   an array of terms, rather than an array of variables: a variable can only
   be substituted when if it is injected in a term (using the [Vari]
   constructor). *)

(** {b NOTE} the result of {!val:to_tvar} can generally NOT be precomputed. A
    first reason is that we cannot know in advance what variable identifier is
    going to arise when working under binders,  for which fresh variables will
    often be generated. A second reason is that free variables should never be
    “marshaled” (e.g., by the {!module:Sign} module), as this would break the
    freshness invariant of new variables. *)

(** [count_products a] returns the number of consecutive products at the  head
    of the term [a]. *)
let rec count_products : term -> int = fun t ->
  match unfold t with
  | Prod(_,b) -> 1 + count_products (Bindlib.subst b Kind)
  | _         -> 0

(** [get_args t] decomposes the {!type:term} [t] into a pair [(h,args)], where
    [h] is the head term of [t] and [args] is the list of arguments applied to
    [h] in [t]. The returned [h] cannot be an [Appl] node. *)
let get_args : term -> term * term list = fun t ->
  let rec get_args acc t =
    match unfold t with
    | Appl(t,u) -> get_args (u::acc) t
    | t         -> (t, acc)
  in get_args [] t

(** [get_args_len t] is similar to [get_args t] but it also returns the length
    of the list of arguments. *)
let get_args_len : term -> term * term list * int = fun t ->
  let rec get_args_len acc len t =
    match unfold t with
    | Appl(t, u) -> get_args_len (u::acc) (len + 1) t
    | t          -> (t, acc, len)
  in
  get_args_len [] 0 t

(** [add_args t args] builds the application of the {!type:term} [t] to a list
    arguments [args]. When [args] is empty, the returned value is (physically)
    equal to [t]. *)
let add_args : term -> term list -> term = fun t args ->
  let rec add_args t args =
    match args with
    | []      -> t
    | u::args -> add_args (Appl(t,u)) args
  in add_args t args

(** [eq ctx t u] tests the equality of [t] and [u] (up to α-equivalence). It
    fails if [t] or [u] contain terms of the form [Patt(i,s,e)] or
    [TEnv(te,env)].  In the process, subterms of the form [TRef(r)] in [t] and
    [u] may be set with the corresponding value to enforce equality, and
    variables appearing in [ctx] can be unfolded. In other words, [eq t u] can
    be used to implement non-linear matching (see {!module:Rewrite}). When the
    matching feature is used, one should make sure that [TRef] constructors do
    not appear both in [t] and in [u] at the same time. Indeed, the references
    are set naively, without checking occurrence. *)
let eq : ctxt -> term -> term -> bool = fun ctx a b -> a == b ||
  let exception Not_equal in
  let rec eq l =
    match l with
    | []       -> ()
    | (a,b)::l ->
    match (Ctxt.unfold ctx a, Ctxt.unfold ctx b) with
    | (a          , b          ) when a == b -> eq l
    | (Vari(x1)   , Vari(x2)   ) when Bindlib.eq_vars x1 x2 -> eq l
    | (Type       , Type       )
    | (Kind       , Kind       ) -> eq l
    | (Symb(s1,_) , Symb(s2,_) ) when s1 == s2 -> eq l
    | (Prod(a1,b1), Prod(a2,b2))
    | (Abst(a1,b1), Abst(a2,b2)) -> let (_, b1, b2) = Bindlib.unbind2 b1 b2 in
                                    eq ((a1,a2)::(b1,b2)::l)
    | (LLet(a1,t1,u1), LLet(a2,t2,u2)) ->
        let (_, u1, u2) = Bindlib.unbind2 u1 u2 in
        eq ((a1,a2)::(t1,t2)::(u1,u2)::l)
    | (Appl(t1,u1), Appl(t2,u2)) -> eq ((t1,t2)::(u1,u2)::l)
    | (Meta(m1,e1), Meta(m2,e2)) when m1 == m2 ->
        eq (if e1 == e2 then l else List.add_array2 e1 e2 l)
    | (Wild       , _          )
    | (_          , Wild       ) -> eq l
    | (TRef(r)    , b          ) -> r := Some(b); eq l
    | (a          , TRef(r)    ) -> r := Some(a); eq l
    | (Patt(_,_,_), _          )
    | (_          , Patt(_,_,_))
    | (TEnv(_,_)  , _          )
    | (_          , TEnv(_,_)  ) -> assert false
    | (_          , _          ) -> raise Not_equal
  in
  try eq [(a,b)]; true with Not_equal -> false

(** [is_symb s t] tests whether [t] is of the form [Symb(s)]. *)
let is_symb : sym -> term -> bool = fun s t ->
  match unfold t with
  | Symb(r,_) -> r == s
  | _         -> false

(** [iter f t] applies the function [f] to every node of the term [t] with
   bound variables replaced by [Kind]. Note: [f] is called on already unfolded
   terms only. *)
let iter : (term -> unit) -> term -> unit = fun action ->
  let rec iter t =
    let t = unfold t in
    action t;
    match t with
    | Wild
    | TRef(_)
    | Vari(_)
    | Type
    | Kind
    | Symb(_)     -> ()
    | Patt(_,_,ts)
    | TEnv(_,ts)
    | Meta(_,ts)  -> Array.iter iter ts
    | Prod(a,b)
    | Abst(a,b)   -> iter a; iter (Bindlib.subst b Kind)
    | Appl(t,u)   -> iter t; iter u
    | LLet(a,t,u) -> iter a; iter t; iter (Bindlib.subst u Kind)
  in iter

(** {3 Metavariables} *)

(** [make_meta ctx a] creates a metavariable of type [a],  with an environment
    containing the variables of context [ctx]. *)
let make_meta : ctxt -> term -> term = fun ctx a ->
  let prd, len = Ctxt.to_prod ctx a in
  let m = fresh_meta prd len in
  let get_var (x,_,_) = Vari(x) in
  Meta(m, Array.of_list (List.rev_map get_var ctx))

(** [iter_meta b f t] applies the function [f] to every metavariable of [t],
   and to the type of every metavariable recursively if [b] is true. *)
let iter_meta : bool -> (meta -> unit) -> term -> unit = fun b f ->
  let rec iter t =
    match unfold t with
    | Patt(_,_,_)
    | TEnv(_,_)
    | Wild
    | TRef(_)
    | Vari(_)
    | Type
    | Kind
    | Symb(_)     -> ()
    | Prod(a,b)
    | Abst(a,b)   -> iter a; iter (Bindlib.subst b Kind)
    | Appl(t,u)   -> iter t; iter u
    | Meta(v,ts)  -> f v; Array.iter iter ts; if b then iter !(v.meta_type)
    | LLet(a,t,u) -> iter a; iter t; iter (Bindlib.subst u Kind)
  in iter

(** [occurs m t] tests whether the metavariable [m] occurs in the term [t]. *)
let occurs : meta -> term -> bool =
  let exception Found in fun m t ->
  let fn p = if m == p then raise Found in
  try iter_meta false fn t; false with Found -> true

(** [get_metas b t] returns the list of all the metavariables in [t], and in
    the types of metavariables recursively if [b], sorted wrt [cmp_meta]. *)
let get_metas : bool -> term -> meta list = fun b t ->
  let open Stdlib in
  let l = ref [] in
  iter_meta b (fun m -> l := m :: !l) t;
  List.sort_uniq cmp_meta !l

(** [has_metas b t] checks whether there are metavariables in [t], and in the
    types of metavariables recursively if [b] is true. *)
let has_metas : bool -> term -> bool =
  let exception Found in fun b t ->
  try iter_meta b (fun _ -> raise Found) t; false with Found -> true

(** [distinct_vars ctx ts]  checks  that terms of  [ts] are made of  variables
    that are themselves or their definition in  [ctx] (if it exists) distinct.
    If so, the variables are returned. *)
let distinct_vars : ctxt -> term array -> tvar array option = fun ctx ts ->
  let exception Not_unique_var in
  let open Stdlib in
  let vars = ref VarSet.empty in
  let to_var t =
    match Ctxt.unfold ctx t with
    | Vari(x) ->
        if VarSet.mem x !vars then raise Not_unique_var;
        vars := VarSet.add x !vars;
        x
    | _       -> raise Not_unique_var
  in
  try Some (Array.map to_var ts) with Not_unique_var -> None

(** [nl_distinct_vars ctx ts] checks that [ts] is made of variables  [vs] only
    and returns some copy of [vs] where variables occurring more than once are
    replaced by fresh variables.  Variables defined in  [ctx] are unfolded. It
    returns [None] otherwise. *)
let nl_distinct_vars : ctxt -> term array -> tvar array option = fun ctx ts ->
  let exception Not_a_var in
  let open Stdlib in
  let vars = ref VarSet.empty
  and nl_vars = ref VarSet.empty in
  let to_var t =
    match Ctxt.unfold ctx t with
    | Vari(x) ->
        if VarSet.mem x !vars then nl_vars := VarSet.add x !nl_vars else
        vars := VarSet.add x !vars;
        x
    | _       -> raise Not_a_var
  in
  let replace_nl_var x =
    if VarSet.mem x !nl_vars then Bindlib.new_var mkfree "_" else x
  in
  try Some (Array.map replace_nl_var (Array.map to_var ts))
  with Not_a_var -> None

(** {3 Conversion of a rule into a "pair" of terms} *)

(** [terms_of_rule r] converts the RHS (right hand side) of the rewriting rule
    [r] into a term.  The bound higher-order variables of the original RHS are
    substituted using [Patt] constructors.  They are thus represented as their
    LHS counterparts. This is a more convenient way of representing terms when
    analysing confluence or termination. *)
let term_of_rhs : rule -> term = fun r ->
  let fn i (name, arity) =
    let make_var i = Bindlib.new_var mkfree (Printf.sprintf "x%i" i) in
    let vars = Array.init arity make_var in
    let p = _Patt (Some(i)) name (Array.map Bindlib.box_var vars) in
    TE_Some(Bindlib.unbox (Bindlib.bind_mvar vars p))
  in
  Bindlib.msubst r.rhs (Array.mapi fn r.vars)