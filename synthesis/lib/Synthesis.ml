open Core
open Ast
open Packet
open Semantics
open Prover
open Manip
open Util
open Tables
       

(* let symbolize x = x ^ "_SYMBOLIC" *)
(* let unsymbolize = String.chop_suffix_exn ~suffix:"_SYMBOLIC" *)
let is_symbolic = String.is_suffix ~suffix:"_SYMBOLIC"

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
           comp x (Value (Int (i,sz)))
    in
    match t with
    | True | False -> t
    | Neg b -> !%(complete_aux_test ~falsify b)
    | And (a, b) -> complete_aux_test ~falsify a %&% complete_aux_test ~falsify b
    | Or (a, b) -> complete_aux_test ~falsify a %+% complete_aux_test ~falsify b
    | Impl (a, b) -> complete_aux_test ~falsify a %=>% complete_aux_test ~falsify b
    | Iff (a, b) -> complete_aux_test ~falsify a %<=>% complete_aux_test ~falsify b
    | Eq (Hole (_,sz), x) | Eq (x, Hole (_,sz)) -> hole_replace x sz (%=%)
    | Le (Hole (_,sz), x) | Le (x, Hole (_,sz)) -> hole_replace x sz (%<=%)
    | Eq _ | Le _ -> t
  and complete_aux ~falsify cmd =
    match cmd with
    | Skip -> cmd
    | Assign (f, v) ->
      begin
        match v with
        | Hole _ ->
           let i = random_int_nin (List.map ~f:fst domain) in
           let sz = int_of_float (2. ** float_of_int i) in
           f %<-% Value (Int (i,sz))
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
              , List.map acts ~f:(fun (data, a) -> (data, complete_aux a ~falsify))
              , complete_aux ~falsify dflt)
  in
  complete_aux ~falsify cmd

let complete cmd = complete_inner ~falsify:true cmd   



                                 

     
                                  
(** Solves the inner loop of the cegis procedure. 
 * pre-condition: pkt is at an ingress host 
**)
(* let get_one_model ?fvs:(fvs = []) mySolver (pkt : Packet.t) (logical : cmd) (phys : cmd) =
 *   let (pkt',_), _ = trace_eval logical (pkt,None) |> Option.value_exn in
 *   (\* let _ = Printf.printf "input: %s\n output: %s\n%!" (Packet.string__packet pkt) (Packet.string__packet pkt') in  *\)
 *   let st = Time.now () in
 *   let phi = Packet.to_test ~fvs pkt' in
 *   let wp_phys_paths = wp_paths phys phi |> List.filter_map ~f:(fun (_,pre) -> pre <> False) in
 *   let wp_time = Time.diff (Time.now ()) st in
 *   (\* if wp_phys_paths = [] then failwith "No feasible paths!" else
 *    *   Printf.printf "%d feasible paths\n\n%!" (List.length wp_phys_paths);
 *    * Printf.printf "------------------------------------------------\n";
 *    * List.iter wp_phys_paths ~f:(fun path ->
 *    *     Printf.printf "%s\n\n%!" (string_of_test path)
 *    *   )
 *    * ; Printf.printf "----------------------------------------------------\n%!"
 *    * ; *\)
 *     let time_spent_in_z3 = ref Time.Span.zero in
 *     let num_calls_to_z3 = ref 0 in
 *     let model =
 *       List.find_map wp_phys_paths ~f:(fun wp_phys ->
 *           let _ = Printf.printf "PHYSICAL WEAKEST_PRECONDITION:\n%s\n\nOF PROGRAM:\n%s\n%!"
 *                     (string_of_test wp_phys)
 *                     (string_of_cmd phys)
 *           in
 *           if wp_phys = False
 *           then (Printf.printf "-- contradictory WP\n%!"; None (\*find_match rest_paths*\))
 *           else
 *             let condition = substV wp_phys pkt in
 *             let _ = Printf.printf "CONDITION: \n%s\n%!" (string_of_test condition) in
 *             num_calls_to_z3 := !num_calls_to_z3 + 1;
 *             match check mySolver `Sat condition with
 *             | (None, d) -> Printf.printf "unsolveable!\n%!";
 *                            time_spent_in_z3 := Time.Span.(!time_spent_in_z3 + d);
 *                            None
 *                              
 *             | Some model, d ->
 *                time_spent_in_z3 := Time.Span.(!time_spent_in_z3 + d);
 *                Some model
 *         )
 *     in
 *     Printf.printf "Took %d reps over %s to find model\n!"
 *       (!num_calls_to_z3)
 *       (Time.Span.to_string !time_spent_in_z3)
 *     ; model, !time_spent_in_z3, !num_calls_to_z3, wp_time *)


let print_instance label linst =
  Printf.printf "%s instance is \n" label;
  StringMap.iteri linst ~f:(fun ~key ~data ->
      Printf.printf "%s -> \n" key;
      List.iter data ~f:(fun (keys,action) ->
          List.iter keys ~f:(fun k -> Printf.printf ",%s" (string_of_expr k));
          Printf.printf "  ---> %d \n%!" action)
      )

              

let get_one_model_edit
      (pkt : Packet.t)
      (data : ProfData.t ref)
      (params : Parameters.t)
      (problem : Problem.t)
  =
  (* print_instance "Logical" (apply_edit linst ledit);
   * print_instance "Physical" pinst; *)
  let linst_edited = Instance.update_list problem.log_inst problem.edits in
  let (pkt',_), wide, trace, actions = trace_eval_inst ~wide:StringMap.empty problem.log linst_edited (pkt,None) in
  let st = Time.now () in
  let cands = CandidateMap.apply_hints `Range params.hints actions problem.phys problem.phys_inst in
  let log_wp = wp trace True in
  let wp_phys_paths =
    List.fold cands ~init:[] ~f:(fun acc (path, acts) ->
        Printf.printf "Candidate:\n%s \n" (string_of_cmd path);
        let precs = if Option.is_none params.hints
                    then
                      [wp path (Packet.to_test ~fvs:problem.fvs pkt')]
                      (* wp_paths ~no_negations:true path (Packet.test_of_wide ~fvs wide) (\* |> List.map ~f:(snd) *\)
                       *                                                (\* Packet.to_test ~fvs pkt' *\)
                       * |> List.map ~f:(fun (trace, _) ->
                       *        let wide_test = Packet.test_of_wide ~fvs wide in
                       *        let wpt = wp trace wide_test in
                       *        Printf.printf "wide packet:\n %s \n%!" (string_of_test wide_test);
                       *        Printf.printf "Candidate :\n %s\n%!" (string_of_cmd trace);
                       *        Printf.printf "WP:\n %s\n%!" (string_of_test wpt);
                       *        wpt) *)
                    else [wp path True]
        in
        acc @ List.map precs ~f:(inj_l acts))
              (* if prec = False then None else Some(prec, acts)) *)
  in
  let _ = Printf.printf "The logical trace is: %s \n%!" (string_of_cmd trace) in
  let wp_time = Time.diff (Time.now ()) st in
  let model =
    List.find_map wp_phys_paths ~f:(fun (wp_phys, acts) ->
        if wp_phys = False then None else
          let _ = Printf.printf "LOGWP %s\n => PHYSWP %s\n%!" (string_of_test log_wp) (string_of_test wp_phys) in
          if holes_of_test wp_phys = [] then
            (Printf.printf "no holes, so skipping\n%!";
            None)
          else
            let (res, time) = check `MinSat (log_wp %=>% wp_phys) in
            data := {!data with
                      model_z3_time = Time.Span.(!data.model_z3_time + time);
                      model_z3_calls = !data.model_z3_calls + 1};
            match res with
            | None -> None
            | Some model -> Some (model, acts)
      )
  in
  data := {!data with search_wp_time = Time.Span.(!data.search_wp_time + wp_time)};
  model

let get_one_model_edit_no_widening
      (pkt : Packet.t)
      (data : ProfData.t ref)
      (params : Parameters.t)
      (problem : Problem.t)
  =
  (* print_instance "Logical" (apply_edit linst ledit);
   * print_instance "Physical" pinst; *)
  let linst_edited =  Instance.update_list problem.log_inst problem.edits in
  let (pkt',_), _, _, actions = trace_eval_inst ~wide:StringMap.empty
                                  problem.log linst_edited (pkt,None) in
  let st = Time.now () in
  let cands = CandidateMap.apply_hints `Exact params.hints actions problem.phys problem.phys_inst in
  let wp_phys_paths =
    List.fold cands ~init:[] ~f:(fun acc (path, acts) ->
        let precs = if Option.is_none params.hints
                    then
                      [wp path (Packet.to_test ~fvs:problem.fvs pkt')]
                    else [wp path True]
        in
        acc @ List.map precs ~f:(inj_l acts))
  in
  let wp_time = Time.diff (Time.now ()) st in
  let model =
    List.find_map wp_phys_paths ~f:(fun (wp_phys, acts) ->
        if wp_phys = False then
          None
        else
          let condition = (Packet.to_test ~fvs:problem.fvs ~random_fill:false pkt %=>% wp_phys) in
          Printf.printf "Checking %s  => %s\n%!" (Packet.to_test ~fvs:problem.fvs ~random_fill:false pkt |> string_of_test) (string_of_test wp_phys);
          if holes_of_test condition = [] then None else
            let (res, time) = check `Sat condition in
            data := {!data with
                      model_z3_time = Time.Span.(!data.model_z3_time + time);
                      model_z3_calls = !data.model_z3_calls + 1
              };
            match res with
            | None -> Printf.printf "no model\n%!";None
            | Some model -> Some (model, acts)
      )
  in
  data := {!data with search_wp_time = Time.Span.(!data.search_wp_time + wp_time)};
  model
    
  

let symbolic_pkt fvs = 
  List.fold fvs ~init:True
    ~f:(fun acc_test (var,sz) ->
      if String.get var 0 |> Char.is_uppercase
         || String.substr_index var ~pattern:("NEW") |> Option.is_some
      then acc_test
      else
        Var (var,sz) %=% Var (symbolize var, sz)
        %&% acc_test)

let symb_wp ?fvs:(fvs=[]) cmd =
  List.dedup_and_sort ~compare (free_vars_of_cmd cmd @ fvs)
  |> symbolic_pkt
  |> wp cmd
  
let implements (data : ProfData.t ref) (problem : Problem.t) =
  (* let _ = Printf.printf "IMPLEMENTS on\n%!    ";
   *         List.iter fvs ~f:(fun (x,_) -> Printf.printf " %s" x);
   *         Printf.printf "\n%!" *)
  (* in *)
  let u_log,_ = problem.log |> Instance.apply `NoHoles `Exact (Instance.update_list problem.log_inst problem.edits)  in
  let u_rea,_ = problem.phys |> Instance.apply `NoHoles `Exact problem.phys_inst in
  let st_mk_cond = Time.now () in
  let condition = equivalent problem.fvs u_log u_rea in
  let nd_mk_cond = Time.now () in
  let mk_cond_time = Time.diff nd_mk_cond st_mk_cond in
  let model_opt, z3time = check_valid condition in
  let pkt_opt = match model_opt with
    | None  -> Printf.printf "++++++++++valid+++++++++++++\n%!";
               `Yes
    | Some x ->
       let pce = Packet.from_CE x |> Packet.un_SSA in
       Printf.printf "----------invalid----------------\n%! CE = %s\n%!" (Packet.string__packet pce)
     ; `NoAndCE pce
  in
  data := {!data with
            eq_time = Time.Span.(!data.eq_time + z3time);
            make_vc_time = Time.Span.(!data.eq_time + mk_cond_time);
            tree_sizes = num_nodes_in_test condition :: !data.tree_sizes
          };
  pkt_opt

                                                         
(** solves the inner loop **)
let rec solve_concrete
          ?packet:(packet=None)
          (data : ProfData.t ref)
          (params : Parameters.t)
          (problem : Problem.t)
        : (Instance.t) =
  let values = multi_ints_of_cmd problem.log |> List.map ~f:(fun x -> Int x) in
  let pkt = packet |> Option.value ~default:(Packet.generate problem.fvs ~values) in
  let model_finder = if params.widening then get_one_model_edit else get_one_model_edit_no_widening in
  match model_finder pkt data params problem with
  | None -> Printf.sprintf "Couldnt find a model" |> failwith
  | Some (model, action_map) ->
     match Instance.fixup_edit model action_map problem.phys problem.phys_inst with
     | `Ok pinst' -> pinst'
     | `Conflict pinst' ->
        Printf.printf "BACKTRACKING\n%!";
        (* failwith "BACKTRACKING" *)
        pinst'
  
let cegis ~iter (params : Parameters.t) (data : ProfData.t ref) (problem : Problem.t) =
  let rec loop (params : Parameters.t) (problem : Problem.t) =
    Printf.printf "======================= LOOP (%d, %d) =======================\n%!%s\n%!" (iter) (params.gas) (Problem.to_string problem);
    let res = implements data problem in
    match Printf.printf "==++?+===++?\n%!"; res with
    | `Yes ->
       Some problem.phys_inst
    | `NoAndCE counter ->
       if params.gas = 0 then failwith "RAN OUT OF GAS" else
         let st = Time.now() in
         let pinst' = solve_concrete ~packet:(Some counter) data params problem in
         let dur = Time.diff (Time.now()) st in
         data := {!data with model_search_time = Time.Span.(!data.model_search_time + dur) };
         if StringMap.equal (=) problem.phys_inst pinst'
         then failwith ("Could not make progress on edits ")
         else loop
                {params with gas = params.gas-1}
                {problem with phys_inst = pinst'}
  in
  let pinst' = loop params problem in
  pinst'
    
let synthesize ~iter (params : Parameters.t) (data : ProfData.t ref)  (problem : Problem.t) =
  let start = Time.now () in
  let pinst' = cegis ~iter params data problem in
  let pinst_out = Option.value ~default:(StringMap.empty) pinst' (*|> complete*) in
  let stop = Time.now() in
  Printf.printf "\nSynthesized Program:\n%s\n\n%!"
    (Instance.apply `NoHoles `Exact pinst_out problem.phys |> fst |> string_of_cmd);
  data := {!data with
            log_inst_size = List.length problem.edits + (Instance.size problem.log_inst);
            phys_inst_size = Instance.size problem.phys_inst;
            time = Time.diff stop start};
  pinst_out
