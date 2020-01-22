open Core
open Ast
open Packet
open Semantics
open Graph
open Prover
open Manip
open Util


       
let apply_edit inst (tbl, edit) =
  StringMap.add_multi inst ~key:tbl  ~data:edit
  
let rec apply_inst tag ?cnt:(cnt=0) inst prog : (cmd * int) =
  match prog with
  | Skip 
    | Assign _
    | Assert _ 
    | Assume _ -> (prog, cnt)
  | Seq (c1,c2) ->
     let (c1', cnt1) = apply_inst tag ~cnt inst c1 in
     let (c2', cnt2) = apply_inst tag ~cnt:cnt1 inst c2 in
     (c1' %:% c2', cnt2)
  | While _ -> failwith "while loops not supported"
  | Select (typ, ss) ->
     let (ss, ss_cnt) =
       List.fold ss ~init:([],cnt)
         ~f:(fun (acc, cnt) (t, c) ->
           let (c', cnt') = apply_inst tag ~cnt inst c in
           acc @ [(t,c')], cnt'
         ) in
     (mkSelect typ ss, ss_cnt)
  | Apply (tbl, keys, acts, def) ->
     let actSize = log2(List.length acts) in
     let instrument_row t act _  =
       let ghost = Skip (* Assume(Hole1("?ActIn"^tbl, actSize) %=% mkVInt(id, actSize))*)
       (* match tag with
        * | `WithHoles -> Assume(Hole1("?ActIn"^tbl, actSize) %=% mkVInt(id, actSize))
        * | `NoHoles -> ("?ActIn"^tbl) %<-% mkVInt(id, actSize) *)
       in
       (t, ghost
           %:% act)
     in
     let selects =
       StringMap.find_multi inst tbl
       |> List.fold ~init:[]
            ~f:(fun acc (matches, action) ->
              let t = List.fold2_exn keys matches
                 ~init:True
                 ~f:(fun acc x m ->
                   (acc %&% (Var1 x %=% m))) in
              if action >= List.length acts then
                []
              else
                instrument_row t (List.nth_exn acts action) action
                :: acc)
     in
     let add_row_hole = Hole1 ("?AddRowTo" ^ tbl, 1) in
     let which_act_hole = Hole1 ("?ActIn" ^ tbl, actSize) in
     let holes =
       match tag with
       | `WithHoles -> 
          List.mapi acts
            ~f:(fun i a -> 
              (List.fold keys ~init:True
                 ~f:(fun acc (x,sz) -> acc %&% (Var1 (x,sz) %=% Hole1 ("?"^x,sz)))
               %&% (add_row_hole %=% mkVInt (1,1))
               %&% (which_act_hole %=% mkVInt (i,actSize))
              , a))
       | `NoHoles -> []
     in
     let dflt_row =
       let cond =
           match tag with
           | `WithHoles -> True (*add_row_hole %=% mkVInt (0,1)*)
           | `NoHoles -> True in
       [instrument_row cond def 3] in
     (selects @ holes @ dflt_row |> mkOrdered
     , cnt (*+ 1*))
           


(* let symbolize x = x ^ "_SYMBOLIC" *)
(* let unsymbolize = String.chop_suffix_exn ~suffix:"_SYMBOLIC" *)
let is_symbolic = String.is_suffix ~suffix:"_SYMBOLIC"
           

(* Computes the traces between two points in graph *)
let find_traces (graph:graph) (in_loc : int) (out_loc : int) =
  let traces = get_all_paths_between graph in_loc out_loc in
  let _ = Printf.printf "ALL PATHS from %d to %d ;\n" in_loc out_loc;
          List.iter traces ~f:(fun tr ->
              Printf.printf "\t[ ";
              List.iter tr ~f:(Printf.printf "%d ");
              Printf.printf "]\n%!") in
  traces



(** [complete] A completion takes a cmd to which a substitution has
   already been applied and replaces the remaining holes with integers
   that are not in the "active domain" of the program. This is a kind
   of an "educated un-guess" i.e. we're guessing values that are
   almost certainly wrong so that on the next run of the CEGIS loop Z3
   will notice and produce a counter example that will take this
   path. The optional [~falsify] flag will replace any [Eq] or [Lt]
   test containing a hole with [False] **)
let complete_inner ~falsify (cmd : cmd) =
  let domain = multi_ints_of_cmd cmd |> dedup in
  let rec complete_aux_test ~falsify t =
    let hole_replace x sz comp =
      if falsify
      then False
      else let i = random_int_nin (List.map ~f:fst domain) in
           comp x (Value1 (Int (i,sz)))
    in
    match t with
    | True | False -> t
    | Neg b -> !%(complete_aux_test ~falsify b)
    | And (a, b) -> complete_aux_test ~falsify a %&% complete_aux_test ~falsify b
    | Or (a, b) -> complete_aux_test ~falsify a %+% complete_aux_test ~falsify b
    | Eq (Hole1 (_,sz), x) | Eq (x, Hole1 (_,sz)) -> hole_replace x sz (%=%)
    | Lt (Hole1 (_,sz), x) | Lt (x, Hole1 (_,sz)) -> hole_replace x sz (%<%)
    | Eq _ | Lt _ -> t
    | Member _ -> failwith "What do?"
  and complete_aux ~falsify cmd =
    match cmd with
    | Skip -> cmd
    | Assign (f, v) ->
      begin
        match v with
        | Hole1 _ ->
           let i = random_int_nin (List.map ~f:fst domain) in
           let sz = int_of_float (2. ** float_of_int i) in
           f %<-% Value1 (Int (i,sz))
        | _ -> cmd
      end
    | Assert b -> Assert (complete_aux_test ~falsify b)
    | Assume b -> Assume (complete_aux_test ~falsify b)
    | Seq (c, c') -> complete_aux ~falsify c %:% complete_aux ~falsify c'
    | While (b, c) -> While (complete_aux_test ~falsify b, complete_aux ~falsify c)
    | Select (styp, ss) ->
       Select(styp, 
               List.map ss
                 ~f:(fun (b, c) ->
                   complete_aux_test ~falsify b , complete_aux ~falsify c )
         )
    | Apply (name, keys, acts, dflt)
      -> Apply (name
              , keys
              , List.map acts ~f:(complete_aux ~falsify)
              , complete_aux ~falsify dflt)
  in
  complete_aux ~falsify cmd

let complete cmd = complete_inner ~falsify:true cmd   



let rec project_cmd_on_acts c (subst : expr1 StringMap.t) : cmd list =
  Printf.printf "PROJECTING\n%!";
  let holes = true in
  match c with
  | Skip -> [c]
  | Assume b ->
     begin  match subst |> substitute ~holes b with
     | False -> []
     | b' -> [Assume b']
     end
  | Assert b -> [subst |> substitute ~holes b |> Assert]
  | Assign (v, e) ->
     begin match StringMap.find subst v with
     | None -> [v %<-% e]
     | Some _ ->
        [v %<-% e]
        (* Printf.printf "Replacing Assignment in %s with %s " v (string_of_expr1 ev);
         * begin match ev %=% e with
         * | False -> []
         * | t -> [Assume t]
         * end *)
     end
  | Seq (c1,c2) ->
     liftL2 mkSeq
       (project_cmd_on_acts c1 subst)
       (project_cmd_on_acts c2 subst)
  | Select (typ, cs) ->
     let open List in
     cs >>= (fun (t, a) ->
       project_cmd_on_acts a subst >>= fun act ->
       let t' = substitute ~holes t subst in
       if t' = False then [] else [(t', act)])
     |> mkSelect typ
     |> return 
  | Apply _ -> failwith "Shouldnt have applys at this stage"
  | While _ -> failwith "idk what to do with while loops"
     


let rec contains_inst_var e =
  match e with
  | Value1 _ -> false
  | Tuple _ -> failwith "tuples not allowed"
  | Var1 (str, _) | Hole1(str,_) ->
     String.is_substring str ~substring:"ActIn"
     || String.is_substring str ~substring:"AddRowTo"
  | Plus (e1,e2) | Times (e1,e2) | Minus(e1,e2)
    -> contains_inst_var e1 || contains_inst_var e2

let rec remove_inst_test b =
  match b with
  | True | False -> b
  | And(b1,b2) -> remove_inst_test b1 %&% remove_inst_test b2
  | Or (b1,b2) -> remove_inst_test b1 %+% remove_inst_test b2
  | Neg b1 -> !%(remove_inst_test b1)
  | Eq(e1,e2) -> if contains_inst_var e1 || contains_inst_var e2
                 then True
                 else b
  | Lt (e1, e2) -> if contains_inst_var e1 || contains_inst_var e2
                   then True
                   else b
  | Member _ -> failwith "Membership unimplemented"
                             
                        
let rec remove_inst_cmd cmd =
  match cmd with
  | Skip -> cmd
  | Assume b -> remove_inst_test b |> Assume
  | Assert b -> remove_inst_test b |> Assert
  | Assign (v, e) ->
     if String.is_substring v ~substring:"ActIn"
        || String.is_substring v ~substring:"AddRowTo"
     then Skip
     else v %<-% e
  | Seq(c1,c2) ->
     remove_inst_cmd c1 %:% remove_inst_cmd c2
  | Select(typ, cs) ->
     List.rev cs
     |> List.fold ~init:[] ~f:(fun acc (v, c) ->
            (remove_inst_test v
            , remove_inst_cmd c)::acc
          )
     |> mkSelect typ
  | Apply _ | While _ -> failwith "Apply/While shouldn't be here"
          
  
                                  
let compute_candidates h pkt phys =
  match h with
  | None -> [phys]
  | Some f ->
     (* Printf.printf "Compute the candidates\n%!"; *)
     let action_mapping =
       let p = StringMap.filter_keys pkt ~f:(String.is_prefix ~prefix:"?ActIn") in
       (* Printf.printf "action mapping is %s" (Packet.string__packet p);        *)
       p |> StringMap.map ~f:(fun v -> Value1 v)
     in
     List.(f action_mapping >>= project_cmd_on_acts phys)
     
                                  
(** Solves the inner loop of the cegis procedure. 
 * pre-condition: pkt is at an ingress host 
**)
let get_one_model ?fvs:(fvs = []) (pkt : Packet.t) (logical : cmd) (phys : cmd) =
  let (pkt',_), _ = trace_eval logical (pkt,None) |> Option.value_exn in
  let _ = Printf.printf "input: %s\n output: %s\n%!" (Packet.string__packet pkt) (Packet.string__packet pkt') in 
  let st = Time.now () in
  let phi = Packet.to_test ~fvs pkt' in
  let wp_phys_paths = wp_paths phys phi  |> List.filter ~f:(fun pre -> pre <> False) in
  let wp_time = Time.diff (Time.now ()) st in
  if wp_phys_paths = [] then failwith "No feasible paths!" else
    Printf.printf "%d feasible paths\n\n%!" (List.length wp_phys_paths);
  Printf.printf "------------------------------------------------\n";
  List.iter wp_phys_paths ~f:(fun path ->
      Printf.printf "%s\n\n%!" (string_of_test path)
    )
  ; Printf.printf "----------------------------------------------------\n%!"
  ;
    let time_spent_in_z3 = ref Time.Span.zero in
    let num_calls_to_z3 = ref 0 in
    let model =
      List.find_map wp_phys_paths ~f:(fun wp_phys ->
          let _ = Printf.printf "PHYSICAL WEAKEST_PRECONDITION:\n%s\n\nOF PROGRAM:\n%s\n%!"
                    (string_of_test wp_phys)
                    (string_of_cmd phys)
          in
          if wp_phys = False
          then (Printf.printf "-- contradictory WP\n%!"; None (*find_match rest_paths*))
          else
            let condition = substV wp_phys pkt in
            let _ = Printf.printf "CONDITION: \n%s\n%!" (string_of_test condition) in
            num_calls_to_z3 := !num_calls_to_z3 + 1;
            match check `Sat condition with
            | (None, d) -> Printf.printf "unsolveable!\n%!";
                           time_spent_in_z3 := Time.Span.(!time_spent_in_z3 + d);
                           None
                             
            | Some model, d ->
               time_spent_in_z3 := Time.Span.(!time_spent_in_z3 + d);
               Some model
        )
    in
    Printf.printf "Took %d reps over %s to find model\n!"
      (!num_calls_to_z3)
      (Time.Span.to_string !time_spent_in_z3)
    ; model, !time_spent_in_z3, !num_calls_to_z3, wp_time


let rec compute_cand_for_trace line t : cmd =
  match line with
  | Skip 
    | Assert _
    | Assume _ 
    | Assign _
    -> line
  | Seq (c1,c2) -> compute_cand_for_trace c1 t
                   %:% compute_cand_for_trace c2 t
  | Select(typ, cs) ->
     List.map cs ~f:(fun (b, c) -> (b, compute_cand_for_trace c t))
     |> mkSelect typ
  | Apply(name, keys, acts, default) ->
     (*might need to use existing instance to negate prior rules *)
     begin match StringMap.find t name with
     | None -> Assume False
     | Some act_idx ->
        if act_idx >= List.length acts
        then default
        else List.fold keys ~init:True
               ~f:(fun acc (x, sz) -> acc %&% (Eq(Var1(x, sz), Hole1("?"^x, sz))))
             |> Assert
             |> Fun.flip mkSeq (List.nth_exn acts act_idx)
     end
  | While _ -> failwith "go away"
  
                                                    
let apply_hints h_opt m pline pinst  =
  match h_opt with
  | None -> [apply_inst `WithHoles pinst pline |> fst, StringMap.empty]
  | Some h ->
     List.map (h m) ~f:(fun t -> (compute_cand_for_trace pline t, t))


let print_instance label linst =
  Printf.printf "%s instance is \n" label;
  StringMap.iteri linst ~f:(fun ~key ~data ->
      Printf.printf "%s -> \n" key;
      List.iter data ~f:(fun (keys,action) ->
          List.iter keys ~f:(fun k -> Printf.printf ",%s" (string_of_expr1 k));
          Printf.printf "  ---> %d \n%!" action)
      )

              

let get_one_model_edit
      ?fvs:(fvs = [])
      ~hints (pkt : Packet.t)
      (lline : cmd) linst ledit
      (pline : cmd) pinst
  =
  (* print_instance "Logical" (apply_edit linst ledit);
   * print_instance "Physical" pinst; *)
  let time_spent_in_z3, num_calls_to_z3 = (ref Time.Span.zero, ref 0) in
  let (pkt',_),trace = trace_eval_inst lline (apply_edit linst ledit) (pkt,None) in
  let st = Time.now () in
  let phi = Packet.to_test ~fvs pkt' in
  let cands = apply_hints hints trace pline pinst in
  (* let _ = Printf.printf "Candidate programs:\n%!";
   *         List.iter cands ~f:(fun (c,_) -> Printf.printf "\n%s\n%!" (string_of_cmd c));
   *         Printf.printf "\n" in *)
  let wp_phys_paths =
    List.filter_map cands ~f:(fun (path, acts) ->
        let prec = wp path phi in
        if prec = False then None else Some(prec, acts))
  in
  let wp_time = Time.diff (Time.now ()) st in
  let model =
    List.find_map wp_phys_paths ~f:(fun (wp_phys, acts) ->
        if wp_phys = False then None else
          let _ = Printf.printf "Packet %s\n wp %s" (Packet.string__packet pkt) (string_of_test wp_phys) in
          let _ = Printf.printf "Checking %s \n%!"
                    (substV wp_phys pkt |> string_of_test) in
          let (res, time) = check `Sat (substV wp_phys pkt) in
          time_spent_in_z3 := Time.Span.(!time_spent_in_z3 + time);
          num_calls_to_z3 := !num_calls_to_z3 + 1;
          match res with
          | None -> None
          | Some model -> Some (model, acts)
      )
  in
  (model, !time_spent_in_z3, !num_calls_to_z3, wp_time)
  
let rec fixup_val (model : value1 StringMap.t) (e : expr1)  : expr1 =
  (* let _ = Printf.printf "FIXUP\n%!" in *)
  let binop op e e' = op (fixup_val model e) (fixup_val model e') in
  match e with
  | Value1 _ | Var1 _ -> e
  | Hole1 (h,sz) -> 
     begin match StringMap.find model h with
     | None -> e
     | Some v -> let sz' = size_of_value1 v in
                 let strv = string_of_value1 v in
                 (if sz <> sz' then
                    (Printf.printf "[Warning] replacing %s#%d with %s, \
                                    but the sizes may be different, \
                                    taking the size of %s to be ground \
                                    truth\n%!" h sz strv strv));
                 Value1 v
     end
  | Plus  (e, e') -> binop mkPlus  e e'
  | Times (e, e') -> binop mkTimes e e'
  | Minus (e, e') -> binop mkMinus e e'
  | Tuple es -> List.map es ~f:(fixup_val model) |> mkTuple

let rec fixup_val2 (model : value1 StringMap.t) (set : expr2) : expr2 =
  match set with
  | Value2 _ | Var2 _ -> set
  | Hole2 _ -> failwith "Second-order holes not supported"
  | Single e -> Single (fixup_val model e)
  | Union (s,s') -> mkUnion (fixup_val2 model s) (fixup_val2 model s')

let rec fixup_test (model : value1 StringMap.t) (t : test) : test =
  let binop ctor call left right = ctor (call left) (call right) in 
  match t with
  | True | False -> t
  | Neg p -> mkNeg (fixup_test model p)
  | And(p, q) -> binop mkAnd (fixup_test model) p q
  | Or(p, q) -> binop mkOr (fixup_test model) p q
  | Eq (v, w) -> binop mkEq (fixup_val model) v w
  | Lt (v, w) -> binop mkLt (fixup_val model) v w
  | Member(v,set) -> mkMember (fixup_val model v) (fixup_val2 model set)

let rec fixup_selects (model : value1 StringMap.t) (es : (test * cmd) list) =
  match es with
  | [] -> []
  | (cond, act)::es' ->
    let cond' = fixup_test model cond in
    let act' = fixup act model in
    (* Printf.printf "  [fixup] replacing %s with %s\n%!"
     *   (string_of_test cond) (string_of_test cond');
     * Printf.printf "  [fixup] replacing %s with %s\n%!" *)
      (* (string_of_cmd act) (string_of_cmd act'); *)
    (cond', act') :: (
      if cond = cond' && act = act' then
        fixup_selects model es'
      else
        (cond, act) :: fixup_selects model es'
    )    
and fixup (real:cmd) (model : value1 StringMap.t) : cmd =
  (* Printf.printf "FIXUP WITH MODEL: %s\n%!\n" (string_of_map model); *)
  match real with
  | Skip -> Skip
  | Assign (f, v) -> Assign(f, fixup_val model v)
  | Assert t -> Assert (fixup_test model t)
  | Assume t -> Assume (fixup_test model t)
  | Seq (p, q) -> Seq (fixup p model, fixup q model)
  | While (cond, body) -> While (fixup_test model cond, fixup body model)
  | Select (styp,cmds) -> fixup_selects model cmds |> mkSelect styp
  | Apply (name, keys, acts, dflt)
    -> Apply (name
            , keys
            , List.map acts ~f:(fun a -> fixup a model)
            , fixup dflt model)

let unroll_fully c = unroll (diameter c) c 

let symbolic_pkt fvs = 
  List.fold fvs ~init:True
    ~f:(fun acc_test (var,sz) ->
      if String.get var 0 |> Char.is_uppercase
         || String.substr_index var ~pattern:("NEW") |> Option.is_some
      then acc_test
      else
        Var1 (var,sz) %=% Var1 (symbolize var, sz)
        %&% acc_test)

let symb_wp ?fvs:(fvs=[]) cmd =
  List.dedup_and_sort ~compare (free_vars_of_cmd cmd @ fvs)
  |> symbolic_pkt
  |> wp cmd
  
let implements fvs logical linst ledit real pinst =
  (* let _ = Printf.printf "IMPLEMENTS on\n%!    ";
   *         List.iter fvs ~f:(fun (x,_) -> Printf.printf " %s" x);
   *         Printf.printf "\n%!" *)
  (* in *)
  let u_log,_ = logical |> apply_inst `NoHoles (apply_edit linst ledit)  in
  let u_rea,_ = real |> apply_inst `NoHoles pinst in
  let st_log = Time.now () in
  let log_wp  = symb_wp u_log ~fvs in
  let log_time = Time.(diff (now()) st_log) in
  let st_real = Time.now () in
  let real_wp = symb_wp u_rea ~fvs in
  let real_time = Time.(diff (now()) st_real) in
  (* Printf.printf "\n==== Checking Implementation =====\n%!\nLOGICAL \
   *                SPEC:\n%s\n\nREAL SPEC: \n%s\n\n%!"
   *   (string_of_test log_wp)
   *   (string_of_test real_wp); *)
  if log_wp = real_wp then Printf.printf "theyre syntactically equal\n%!";
  let condition = log_wp %<=>% real_wp in
  let model_opt, z3time = check_valid condition in
  let pkt_opt = match model_opt with
    | None  -> Printf.printf "++++++++++valid+++++++++++++\n%!";
               `Yes
    | Some x ->
       let pce = Packet.from_CE x in
       Printf.printf "----------invalid----------------\n%! CE = %s\n%!" (Packet.string__packet pce)
     ; `NoAndCE pce
  in pkt_opt, z3time, log_time, real_time, num_nodes_in_test condition


let rec get_schema_of_table name phys =
  match phys with
  | Skip 
    | Assume _
    | Assert _
    | Assign _
    -> None
  | Seq (c1, c2) ->
     begin match get_schema_of_table name c1 with
     | None -> get_schema_of_table name c2
     | Some ks -> Some ks
     end
  | Select (_, cs) ->
     List.find_map cs ~f:(fun (_, c) -> get_schema_of_table name c)
  | Apply(name', ks, acts, def)
    -> if name = name' then Some (ks,acts,def) else None
  | While (_, c) -> get_schema_of_table name c



let fixup_edit match_model action_map phys (pinst : (expr1 list * int) list Util.StringMap.t) =
  let mk_new_row tbl_name act =
    match get_schema_of_table tbl_name phys with
    | None -> failwith ("Couldnt find keys for table " ^ tbl_name)
    | Some (ks, _, _) ->
       let keys_holes =
         List.fold ks ~init:(Some [])
           ~f:(fun acc (v, sz) ->
             match acc, fixup_val match_model (Hole1("?"^v,sz)) with
             | None, _ -> None
             | _, Hole1 _ -> None
             | Some ks, v -> Some (ks @ [v])
           ) in
       match keys_holes with
       | None -> []
       | Some ks -> [(ks, act)]
  in
  StringMap.fold ~init:pinst action_map ~f:(fun ~key:tbl_name ~data:act acc ->
      StringMap.update acc tbl_name
        ~f:(function
          | None -> mk_new_row tbl_name act
          | Some rows -> rows @ mk_new_row tbl_name act

        )
    )
                                                         
(** solves the inner loop **)
let solve_concrete
      ?fvs:(fvs = [])
      ~hints ?packet:(packet=None)
      (logical : cmd) linst edit
      (phys : cmd) pinst
    : (((expr1 list * int) list) StringMap.t * Time.Span.t * int * Time.Span.t) =
  let values = multi_ints_of_cmd logical |> List.map ~f:(fun x -> Int x) in
  let pkt = packet |> Option.value ~default:(Packet.generate fvs ~values) in
  match get_one_model_edit ~fvs ~hints pkt logical linst edit phys pinst with
  | None, z3time, ncalls, _ ->
     Printf.sprintf "Couldnt find a model in %d calls and %f"
       ncalls (Time.Span.to_ms z3time)
     |> failwith
  | Some (model, action_map), z3time, ncalls, wp_time ->
     let pinst' = fixup_edit model action_map phys pinst in
     print_instance "NEW Physical" pinst';
     pinst', z3time, ncalls, wp_time
  
let cegis ?fvs:(fvs = []) ~hints ?gas:(gas=1000) (logical : cmd) linst ledit (real : cmd) pinst =
  let fvs = if fvs = []
            then (Printf.printf "Computing the FVS!\n%!";
                  free_vars_of_cmd logical @ free_vars_of_cmd real)
            else fvs in
  let implements_time = ref Time.Span.zero in
  let implements_calls = ref 0 in
  let model_time = ref Time.Span.zero in
  let model_calls = ref 0 in
  let wp_time = ref Time.Span.zero in
  let log_wp_time = ref Time.Span.zero in
  let phys_wp_time = ref Time.Span.zero in
  let tree_sizes = ref [] in
  let rec loop gas pinst =
    Printf.printf "======================= LOOP (%d) =======================\n%!" (gas);
    let (res, z3time, log_time, phys_time, treesize) =
      implements fvs logical linst ledit real pinst in
    implements_time := Time.Span.(!implements_time + z3time);
    implements_calls := !implements_calls + 1;
    log_wp_time := Time.Span.(!log_wp_time + log_time);
    phys_wp_time := Time.Span.(!phys_wp_time + phys_time);
    tree_sizes := treesize :: !tree_sizes;
    match Printf.printf "==++?+===++?\n%!"; res with
    | `Yes ->
       Some pinst
    | `NoAndCE counter ->
       if gas = 0 then Some pinst else
         let (pinst', ex_z3_time, ncalls, wpt) =
           solve_concrete ~fvs ~hints ~packet:(Some counter) logical linst ledit real pinst in
         model_time := Time.Span.(!model_time + ex_z3_time);
         model_calls := !model_calls + ncalls;
         wp_time := Time.Span.(!wp_time + wpt);
         loop (gas-1) pinst'
  in
  let pinst' = loop gas pinst in
  Printf.printf "total z3 time to synthesize %s + %s = %s\n%!"
    (Time.Span.to_string !implements_time)
    (Time.Span.to_string !model_time)
    (Time.Span.(to_string (!implements_time + !model_time)));
  (pinst', !implements_time, !implements_calls, !model_time, !model_calls, !wp_time, !log_wp_time, !phys_wp_time, !tree_sizes)
    
let synthesize ?fvs:(fvs=[]) ?hints:(hints = None) ?gas:(gas = 1000)
      logical linst ledit phys pinst =
  let start = Time.now () in
  let (pinst', checktime, checkcalls, searchtime, searchcalls, wpt, lwpt, pwpt, tree_sizes) =
    cegis ~fvs ~hints ~gas logical linst ledit phys pinst in
  let pinst_out = Option.value ~default:(StringMap.empty) pinst' (*|> complete*) in
  let stop = Time.now() in
  Printf.printf "\nSynthesized Program:\n%s\n\n%!"
    (apply_inst `NoHoles pinst_out phys |> fst |> string_of_cmd);
  (Time.diff stop start, checktime, checkcalls, searchtime, searchcalls, wpt, lwpt, pwpt, tree_sizes, pinst_out)



   
let synthesize_edit ?fvs:(fvs=[]) ?hints:(hints=None)
      ?gas:(gas=1000)
      (log_pipeline : cmd) (phys_pipeline : cmd)
      (linst :  (expr1 list * int) list StringMap.t)
      (pinst : (expr1 list * int) list StringMap.t)
      (ledit : (string * (expr1 list * int))) =  
  Printf.printf "Logical:\n%s\n\nPhysical:\n%s\n"
    (string_of_cmd (apply_inst `NoHoles (apply_edit linst ledit) log_pipeline |> fst))
    (string_of_cmd (apply_inst `NoHoles pinst phys_pipeline |> fst));
  print_instance "Logical" linst;
  print_instance "Physical" pinst;
  synthesize ~fvs ~gas ~hints (log_pipeline) linst ledit
    (phys_pipeline) pinst
    
