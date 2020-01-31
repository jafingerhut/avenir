open Core
open Ast
open Util



(* computes the product of two lists of disjuncitons *)
let multiply orlist orlist' =
  let foil outer inner =
    List.fold outer ~init:[] ~f:(fun acc x ->
        List.map inner ~f:(mkAnd x)
        @ acc
      )
  in
  foil orlist orlist'
  @ foil orlist' orlist
    
  
(* Computes the Negation Normal Form of a test*)               
let rec nnf t : test =
  match t with
  | Eq(_, _)
  | Le(_, _)
  | Member(_,_)
  | True
  | False
  | Neg(Eq(_, _))
  | Neg(Le(_, _))
  | Neg(Member(_,_))
  | Neg(True)
  | Neg(False) -> t
  | Neg (Neg t) -> nnf t
  | And (a, b) -> mkAnd (nnf a) (nnf b)
  | Or (a, b) -> mkOr (nnf a) (nnf b)
  | Impl (a, b) -> nnf (!%(a) %+% b)
  | Iff (a, b) -> nnf (mkAnd (Impl(a,b)) (Impl (b,a)))
  | Neg(And(a, b)) -> mkOr (mkNeg a) (mkNeg b) |> nnf
  | Neg(Or(a, b)) -> mkAnd (mkNeg a) (mkNeg b) |> nnf
  | Neg(Impl(a, b)) -> mkAnd a (mkNeg b) |> nnf
  | Neg(Iff (a, b)) -> mkOr (mkAnd a (mkNeg b)) (mkAnd (mkNeg b) a)



                         

(* Computes the Disjunctive Normal form of a test *)
let rec dnf t : test list =
  let t' = nnf t in
  match t' with
  | And(a, b) -> multiply (dnf a) (dnf b)
  | Or (a, b) -> dnf a @ dnf b
  | Impl(a, b) -> dnf (nnf (!%(a) %+% b))
  | Iff(a,b) -> dnf (Impl (a,b) %&% Impl(b,a))
  | Member (_,_)
  | Eq _
  | Le _ 
  | Neg _ (* will not be And/Or because NNF*)
  | True
  | False  ->  [t']


                 
                 
(* Unrolls all loops in the program p n times *)
let rec unroll n p =
  match p, n with
  | While (_, _), 0 -> Skip
  | While (cond, body), _ -> 
    mkPartial [cond , (body %:% unroll (n-1) p)]
    (* %:% Assert (!% cond) *)
  | Seq (firstdo, thendo), _ ->
    Seq (unroll n firstdo, unroll n thendo)
  | Select (styp, cmds), _ ->
    List.map cmds ~f:(fun (cond, action) -> (cond, unroll n action))
    |> mkSelect styp
  | _ -> p (* Assign, Test, Assert cannot be unrolled *)

let get_val subsMap str default =
  StringMap.find subsMap str |> Option.value ~default

                                             
(** computes ex[xs -> vs], replacing only Vars whenever holes is false, replacing both whenever holes is true *)
let rec substitute ?holes:(holes = false) ex subsMap =
  let subst = get_val subsMap in
  let rec substituteE e =
    match e with
    | Var1 (field,_) -> subst field e
    | Hole1 (field,_) ->
       if holes then
         let e' = subst field e in
         ((*Printf.printf "%s -> %s \n%!" field (string_of_expr1 e');*)
          e')
       else ((*Printf.printf "NO SUBST\n%!";*)  e)
    | Value1 _ -> e
    | Plus (e, e') -> Plus (substituteE e, substituteE e')
    | Times (e, e') -> Times (substituteE e, substituteE e')
    | Minus (e, e') -> Minus (substituteE e, substituteE e')
    | Tuple es -> List.map es ~f:substituteE |> Tuple
  in
  match ex with
  | True | False -> ex
  (* Homomorphic Rules*)               
  | Neg e       -> !%(substitute ~holes e subsMap)
  | Or   (e, e') -> substitute ~holes e subsMap %+% substitute ~holes e' subsMap
  | And  (e, e') -> substitute ~holes e subsMap %&% substitute ~holes e' subsMap
  | Impl (e, e') -> substitute ~holes e subsMap %=>% substitute ~holes e' subsMap
  | Iff  (e, e') -> substitute ~holes e subsMap %<=>% substitute ~holes e' subsMap
  (* Do the work *)
  | Eq (e,e') ->  substituteE e %=% substituteE e'
  | Le (e,e') ->  substituteE e %<=% substituteE e'
  | Member(e,set) -> Member(substituteE e, set)

let substV ?holes:(holes = false) ex substMap =
  StringMap.map substMap ~f:(fun v -> Value1 v)
  |> substitute ~holes ex

let rec exact_only t =
  match t with
  | Le _ | Member _ -> false
  | True | False | Eq _ -> true
  | Neg(a) -> exact_only a
  | And(a,b) | Or(a,b) | Impl(a,b) | Iff(a,b)
    -> exact_only a && exact_only b

let regularize cond misses =
  cond %&% !%misses
  (* if exact_only cond
   * then if cond = True
   *      then !%misses
   *      else cond &
   * else failwith "Don't know how to regularize anything but equivalences"  *)
         
                
(* computes weakest pre-condition of condition phi w.r.t command c *)
let rec wp c phi =
  let guarded_wp (cond, act) = cond %=>% wp act phi in
  match c with
  | Skip -> phi
  | Seq (firstdo, thendo) ->
    wp firstdo (wp thendo phi)
  | Assign (field, value) ->
     substitute phi (StringMap.singleton field value)
  | Assert t -> t %&% phi
  | Assume t -> t %=>% phi
              
  (* requires at least one guard to be true *)
  | Select (Total, []) -> True
  | Select (Total, cmds) ->
    concatMap cmds ~c:(%+%) ~f:fst 
    %&% concatMap cmds ~c:(%&%) ~f:guarded_wp
    
  (* doesn't require at any guard to be true *)
  | Select (Partial, []) -> True
  | Select (Partial, cmds) ->
     concatMap cmds ~c:(%&%) ~f:guarded_wp

  (* negates the previous conditions *)
  | Select (Ordered, cmds) ->
     List.fold cmds ~init:(True, False) ~f:(fun (wp_so_far, misses) (cond, act) ->
         let guard = regularize cond misses in
        ((guard %=>% wp act phi) %&% wp_so_far
        , cond %+% misses )
      )
    |> fst

  | Apply (_, _, acts, dflt)
    -> concatMap acts ~f:(fun (scope, a) -> wp (holify (List.map scope ~f:fst) a) phi) ~c:(mkAnd) ~init:(Some True)
      %&% wp dflt phi
  | While _ ->
    Printf.printf "[WARNING] skipping While loop, because loops must be unrolled\n%!";
    phi

let freshen v sz i = (v ^ "$" ^ string_of_int i, sz)
      
let good_execs fvs c =
  let binop f sub l op r = op (f l sub) (f r sub) in
  let rec indexVars_expr1 e (sub : ((int * int) StringMap.t)) =
    match e with
    | Var1 (x,sz) ->
       begin match StringMap.find sub x with
       | None  -> "couldn't find "^x^" in substitution map with keys"
                  ^ (StringMap.keys sub |> List.fold ~init:"" ~f:(fun acc k -> Printf.sprintf "%s %s" acc k))
                  |> failwith
       | Some (i,_) ->  Var1 (freshen x sz i)
       end
    | Hole1 (x, sz) ->
       begin match StringMap.find sub x with
       | None  -> "couldn't find "^x^" in substitution map " |> failwith
       | Some (i,_) ->  Hole1 (freshen x sz i)
       end
    | Value1 _ -> e
    | Plus(e1,e2) -> Plus(indexVars_expr1 e1 sub, indexVars_expr1 e2 sub)
    | Minus(e1,e2) -> Minus(indexVars_expr1 e1 sub, indexVars_expr1 e2 sub)
    | Times(e1,e2) -> Times(indexVars_expr1 e1 sub, indexVars_expr1 e2 sub)
    | Tuple es -> List.map es ~f:(fun e -> indexVars_expr1 e sub) |> Tuple
  in
  let rec indexVars b sub =
    match b with
    | True | False -> b
    | Neg b -> !%(indexVars b sub)
    | And  (a,b) -> binop indexVars       sub a (%&%)   b
    | Or   (a,b) -> binop indexVars       sub a (%+%)   b
    | Impl (a,b) -> binop indexVars       sub a (%=>%)  b
    | Iff  (a,b) -> binop indexVars       sub a (%<=>%) b
    | Eq (e1,e2) -> binop indexVars_expr1 sub e1 (%=%) e2
    | Le (e1,e2) -> binop indexVars_expr1 sub e1 (%<=%) e2
    | Member _ -> failwith "Member unimplemented"
  in
  let rec passify sub c : ((int * int) StringMap.t * cmd) =
    match c with
    | Skip -> (sub, Skip)
    | Assert b ->
       (sub, Assert (indexVars b sub))
    | Assume b ->
       (sub, Assert (indexVars b sub))
    | Assign (f,e) ->
       begin match StringMap.find sub f with
       | None ->
          let sz = size_of_expr1 e in
          (StringMap.set sub ~key:f ~data:(1, sz)
          , Assume (Var1 (freshen f sz 0) %=% indexVars_expr1 e sub))
       | Some (idx, sz) ->
          (StringMap.set sub ~key:f ~data:(idx + 1,sz)
          , Assume (Var1 (freshen f sz (idx + 1)) %=% (indexVars_expr1 e sub)))
       end
    | Seq (c1, c2) ->
       let (sub1, c1') = passify sub  c1 in
       let (sub2, c2') = passify sub1 c2 in
       (sub2, c1' %:% c2')
    | Select (Total, _) -> failwith "Don't know what to do for if total"
    | Select (typ, ss) ->
       let sub_lst = List.map ss ~f:(fun (t,c) ->
                         let sub', c' = passify sub c in
                         (sub', (indexVars t sub, c'))) in
       let merged_subst =
         List.fold sub_lst ~init:StringMap.empty
           ~f:(fun acc (sub', _) ->
             StringMap.merge acc sub'
               ~f:(fun ~key:_ ->
                 function
                 | `Left i -> Some i
                 | `Right i -> Some i
                 | `Both ((i,sz),(j,_)) -> Some (max i j, sz)))
       in
       let rewriting sub =
         StringMap.fold sub ~init:Skip
           ~f:(fun ~key:v ~data:(idx,_) acc ->
             let merged_idx,sz = StringMap.find_exn merged_subst v in
             if merged_idx > idx then
               Assume (Var1(freshen v sz merged_idx)
                       %=% Var1(freshen v sz idx))
               %:% acc
             else acc
           )
       in
       let ss' =
         List.filter_map sub_lst ~f:(fun (sub', (t', c')) ->
             let rc = rewriting sub' in
             Printf.printf "Inserting padding %s" (string_of_cmd rc);
             Some (t', c' %:% rc)
           )
       in
       (merged_subst, mkSelect typ ss')
         
    | While _ ->
       failwith "Cannot passify While loops Unsupported"
    | Apply _ ->
       failwith "Cannot passify (yet) table applications"
  in
  let rec good_wp c =
    match c with
    | Skip -> True
    | Assert b
      | Assume b -> b
    | Seq (c1,c2) -> good_wp c1 %&% good_wp c2
    | Select(Total, _) -> failwith "Totality eludes me"
    | Select(Partial, ss) ->
       List.fold ss ~init:(True)
         ~f:(fun acc (t,c) -> acc %+% (t %&% good_wp (c)))
    | Select(Ordered,  ss) ->
       List.fold ss ~init:(False,False)
         ~f:(fun (cond, misses) (t,c) ->
           (cond %+% (
              t %&% !%(misses) %&% good_wp c
            )
           , t %+% misses))
       |> fst
    | Assign _ -> failwith "ERROR: PROGRAM NOT IN PASSIVE FORM! Assignments should have been removed"
    | While _ -> failwith "While Loops Deprecated"
    | Apply _ -> failwith "Tables should be applied at this stage"
  in
  let init_sub = List.fold fvs ~init:StringMap.empty ~f:(fun sub (v,sz) ->
                     StringMap.set sub ~key:v ~data:(0,sz)
                   ) in
  Printf.printf "active : \n %s \n" (string_of_cmd c);
  let merged_sub, passive_c = passify init_sub c  in
  Printf.printf "passive : \n %s\n" (string_of_cmd passive_c);
  (merged_sub, good_wp passive_c)


let inits fvs sub =
  StringMap.fold sub ~init:[]
    ~f:(fun ~key:v ~data:(_,sz) vs ->
      if List.exists fvs ~f:(fun (x,_) -> x = v)
      then (freshen v sz 0) :: vs
      else vs)
  |> List.sort ~compare:(fun (u,_) (v,_) -> compare u v)

let finals fvs sub =
  StringMap.fold sub ~init:[]
    ~f:(fun ~key:v ~data:(i,sz) vs ->
      if List.exists fvs ~f:(fun (x,_) -> x = v)
      then (freshen v sz i) :: vs
      else vs)
  |> List.sort ~compare:(fun (u,_) (v,_) -> compare u v)

let zip_eq_exn xs ys =
  List.fold2_exn xs ys ~init:True ~f:(fun acc x y -> acc %&% (Var1 x %=% Var1 y) )

let rec prepend_expr1 pfx e =
  match e with
  | Value1 _ -> e
  | Var1 (v,sz) -> Var1(pfx^v, sz)
  | Hole1(v, sz) -> Var1(pfx^v, sz)
  | Plus (e1, e2) -> Plus(prepend_expr1 pfx e1, prepend_expr1 pfx e2)
  | Minus (e1, e2) -> Minus(prepend_expr1 pfx e1, prepend_expr1 pfx e2)
  | Times (e1, e2) -> Times(prepend_expr1 pfx e1, prepend_expr1 pfx e2)
  | Tuple es -> List.map es ~f:(prepend_expr1 pfx) |> Tuple

let rec prepend_test pfx b =
  match b with
  | True | False -> b
  | Neg b -> !%(prepend_test pfx b)
  | Eq(e1,e2) -> prepend_expr1 pfx e1 %=% prepend_expr1 pfx e2
  | Le(e1,e2) -> prepend_expr1 pfx e1 %<=% prepend_expr1 pfx e2
  | And(b1,b2) -> prepend_test pfx b1 %&% prepend_test pfx b2
  | Or(b1,b2) -> prepend_test pfx b1 %+% prepend_test pfx b2
  | Impl(b1,b2) -> prepend_test pfx b1 %=>% prepend_test pfx b2
  | Iff (b1,b2) -> prepend_test pfx b1 %<=>% prepend_test pfx b2
  | Member _ -> failwith "deprecated"

let rec prepend pfx c =
  match c with
  | Skip -> Skip
  | Assign(f,e) -> Assign(pfx^f, prepend_expr1 pfx e)
  | Assert b -> prepend_test pfx b |> Assert
  | Assume b -> prepend_test pfx b |> Assume
  | Seq(c1,c2) -> prepend pfx c1 %:% prepend pfx c2
  | While (b,c) -> mkWhile (prepend_test pfx b) (prepend pfx c)
  | Select(typ, cs) ->
     List.map cs ~f:(fun (t,c) -> (prepend_test pfx t, prepend pfx c))
     |> mkSelect typ
  | Apply(name, keys, acts, def) ->
     Apply(pfx ^ name
         , List.map keys ~f:(fun (k,sz) -> (pfx ^ k, sz))
         , List.map acts ~f:(fun (scope, act) -> (List.map scope ~f:(fun (x,sz) -> (pfx ^ x, sz)), prepend pfx act))
         , prepend pfx def)
  
                 
let equivalent eq_fvs l p =
  let phys_prefix = "phys_"in
  let p' = prepend phys_prefix p in
  let fvs =
    free_of_cmd `Hole l
    @ free_of_cmd `Var l
    @ free_of_cmd `Hole p
    @ free_of_cmd `Var p
  in
  let prefix_list =  List.map ~f:(fun (x,sz) -> (phys_prefix ^ x, sz)) in
  let fvs_p = prefix_list fvs in
  let eq_fvs_p = prefix_list eq_fvs in
  let sub_l, gl = good_execs fvs l in
  let sub_p, gp = good_execs fvs_p p' in
  let lin = inits eq_fvs sub_l in
  let pin = inits eq_fvs_p sub_p in
  let lout = finals eq_fvs sub_l in
  let pout = finals eq_fvs_p sub_p in
  (* let _ = Printf.printf "lin: ";
   *         List.iter lin ~f:(fun (v, _) -> Printf.printf " %s" v);
   *         Printf.printf "\n";
   *         Printf.printf "pin: ";
   *         List.iter pin ~f:(fun (v, _) -> Printf.printf " %s" v);
   *         Printf.printf "\n"
   * in *)
  let in_eq = zip_eq_exn lin pin in
  let out_eq = zip_eq_exn lout pout in
  (* Printf.printf "===Verifying===\n%s\nand\n%s\nand\n%s\nimplies\n%s"
   *   (string_of_test gl)
   *   (string_of_test gp)
   *   (string_of_test in_eq)
   *   (string_of_test out_eq); *)
  (gl %&% gp %&% in_eq) %=>% out_eq

    
  

(** [fill_holes(|_value|_test]) replace the applies the substitution
   [subst] to the supplied cmd|value|test. It only replaces HOLES, and
   has no effect on vars *)
let rec fill_holes_expr1 e (subst : value1 StringMap.t) =
  let fill_holesS e = fill_holes_expr1 e subst in
  let binop op e e' = op (fill_holesS e) (fill_holesS e') in
  match e with
  | Value1 _ | Var1 _ -> e
  | Hole1 (h,sz) ->
     begin match StringMap.find subst h with
     | None -> e
     | Some v -> let sz' = size_of_value1 v in
                 let strv = string_of_value1 v in
                 (if sz <> sz' then (Printf.printf "[Warning] replacing %s#%d with %s#%d, but the sizes may be different, taking the size of %s to be ground truth" h sz strv (size_of_value1 v) strv));
                 Value1 v
     end
  | Plus (e, e') -> binop mkPlus e e'
  | Minus (e, e') -> binop mkMinus e e'
  | Times (e, e') -> binop mkTimes e e'
  | Tuple es -> List.map es ~f:(fill_holesS) |> Tuple


(* Fills in first-order holes according to subst  *)                  
let rec fill_holes_test t subst =
  let binop cnstr rcall left right = cnstr (rcall left subst) (rcall right subst) in
  match t with
  | True | False -> t
  | Neg a -> mkNeg (fill_holes_test a subst)
  | And  (a, b)   -> binop (%&%)   fill_holes_test  a b
  | Or   (a, b)   -> binop (%+%)   fill_holes_test  a b
  | Impl (a, b)   -> binop (%=>%)  fill_holes_test  a b
  | Iff  (a, b)   -> binop (%<=>%) fill_holes_test  a b
  | Le   (a, b)   -> binop (%<=%)  fill_holes_expr1 a b
  | Eq   (a, b)   -> binop (%=%)   fill_holes_expr1 a b
  | Member (a, s) -> Member(fill_holes_expr1 a subst, s)

let rec fill_holes (c : cmd) subst =
  let rec_select = concatMap ~c:(@)
                     ~f:(fun (cond, act) ->
                       [(fill_holes_test cond subst, fill_holes act subst)]) in
  match c with
  | Assign (f, Hole1 (h,sz)) ->
     begin match StringMap.find subst h with
     | None -> c
     | Some v -> let sz' = size_of_value1 v in
                 let strv = string_of_value1 v in
                 (if sz <> sz' then (Printf.printf "[Warning] replacing %s#%d with %s#%d, but the sizes may be different, taking the size of %s to be ground truth" h sz strv (size_of_value1 v) strv));
                 Assign (f, Value1 v)
     end
  | Assign (_, _) -> c
  | Seq (firstdo, thendo) ->
     fill_holes firstdo subst %:% fill_holes thendo subst
  | Assert t ->
     fill_holes_test t subst |> Assert
  | Assume t ->
     fill_holes_test t subst |> Assume
  | Select (_,[]) | Skip ->
     c
  | Select (styp, cmds) ->
     rec_select cmds |> mkSelect styp
  | While (cond, body) -> While (fill_holes_test cond subst, fill_holes body subst)
  | Apply (n,keys, acts, dflt)
    -> Apply(n, keys
             , List.map acts ~f:(fun (scope, a) -> (scope, fill_holes a subst))
             , fill_holes dflt subst)
            


let rec wp_paths c phi : (cmd * test) list =
  match c with
  | Skip -> [(c, phi)]
  | Seq (c1, c2) ->
     List.map (wp_paths c2 phi)
       ~f:(fun (trace2, phi) ->
         List.map (wp_paths c1 phi)
           ~f:(fun (trace1, phi') ->
             (trace1 %:% trace2, phi')
           ) 
       ) |> List.join
       
  | Assign (field, e) ->
     let phi' = substitute phi (StringMap.singleton field e) in 
     (* Printf.printf "substituting %s |-> %s\n into %s to get %s \n%!" field (string_of_expr1 e) (string_of_test phi') (string_of_test phi'); *)
     [(c,phi')]
  | Assert t -> [(c, t %&% phi)]
  | Assume t -> [(c, t %=>% phi)]
                  
  (* requires at least one guard to be true *)
  | Select (Total, []) -> [(Skip, True)]
  | Select (Total, cmds) ->
     let open List in
     (cmds >>| fun (t,c) -> Assert t %:% c)
     >>= Fun.flip wp_paths phi

                  
  (* doesn't require at any guard to be true *)
  | Select (Partial, []) -> [(Skip, True)]
  | Select (Partial, cmds) ->
     let open List in
     (cmds >>| fun (t,c) -> Assume t %:% c)
     >>= Fun.flip wp_paths phi
                  
  (* negates the previous conditions *)
  | Select (Ordered, cmds) ->
     (* let open List in
      * (cmds >>| fun (t,c) -> Assume t %:% c)
      * >>= Fun.flip wp_paths phi *)
     List.fold cmds ~init:([], False) ~f:(fun (wp_so_far, prev_conds) (cond, act) ->
         List.fold (wp_paths act phi) ~init:wp_so_far
           ~f:(fun acc (trace, act_wp) ->
             acc @[(Assert cond %:% trace, cond %&% !%prev_conds %&% act_wp)]), prev_conds %+% cond)
     |> fst

  | Apply (_, _, acts, dflt) ->
     let open List in
     (dflt :: List.map ~f:(fun (sc, a) -> holify (List.map sc ~f:fst) a) acts) >>= Fun.flip wp_paths phi
  | While _ ->
     failwith "[Error] loops must be unrolled\n%!"


              
let bind_action_data vals (scope, cmd) : cmd =
  let holes = List.map scope fst in
  Printf.printf "Table |holes| = %d, |vars|= %d\n : %s" (List.length holes) (List.length vals) (string_of_cmd cmd);
  List.fold2_exn holes vals
    ~init:StringMap.empty
    ~f:(fun acc x v -> StringMap.set acc ~key:x ~data:(Int v))
  |> fill_holes (holify holes cmd) 
