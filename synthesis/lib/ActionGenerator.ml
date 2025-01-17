open Core
open Util

type t =
  { target_vars: StringSet.t
  ; (*vars that need to be affected*)
    source_keys: StringSet.t
        (* The keys that must be able to influence the affected vars *) }

let mkstate s t =
  let open StringSet in
  let target_vars = diff t s in
  let source_keys = diff s t in
  {target_vars; source_keys}

let partition_on_finished flows =
  List.partition_map flows ~f:(fun ((st, _) as flow) ->
      if
        StringSet.is_empty st.target_vars
        (*&& StringSet.is_empty st.source_keys*)
      then First flow
      else Second flow )

(* return all traces of tables and actions on which every non_trivial_key flows to the keys in affected vars
 * the traces that have no source_keys are the completely determined ones that we can
 *)
let rec flows c (st : t) : (t * (string * int) list) list =
  let open Cmd in
  match c with
  | Skip | Assume _ -> [(st, [])]
  | Assign (f, e) ->
      let target_vars = StringSet.remove st.target_vars f in
      let target_vars =
        Expr.frees `Var e |> fsts |> stringset_add_list target_vars
      in
      [({st with target_vars}, [])]
  | Seq (c1, c2) ->
      let open List in
      let finished_flows, unfinished_flows =
        flows c2 st |> partition_on_finished
      in
      finished_flows
      @ bind unfinished_flows ~f:(fun (st2, trace2) ->
            flows c1 st2 |> map_snd ~f:(fun trace1 -> trace1 @ trace2) )
  | Select (_, cs) -> List.bind cs ~f:(fun (_, c) -> flows c st)
  | Apply t ->
      let open StringSet in
      let keys = of_list @@ fsts @@ free_keys t.keys in
      List.filter_mapi t.actions ~f:(fun act_id (_, params, act) ->
          let act_vars = assigned_vars act in
          let isect = inter act_vars st.target_vars in
          if is_empty isect then None
          else
            let st, _ = flows act st |> List.hd_exn in
            let params = of_list @@ fsts params in
            let source_keys = diff st.source_keys keys in
            let targetable_keys = diff keys st.source_keys in
            (* remove usable keys, what remains are the targetable keys *)
            let unbound_targets = diff st.target_vars params in
            (* remove parameters *)
            let target_vars = union unbound_targets targetable_keys in
            Some (mkstate source_keys target_vars, [(t.name, act_id)]) )
      @ flows t.default st

let print t =
  List.iter t ~f:(fun (table, actions) ->
      Printf.printf "%s:%!" table ;
      List.iter actions ~f:(fun (params, act_id, action) ->
          Printf.printf "\naction[%d] \\%s ->\n%s" act_id
            (List.fold params ~init:"" ~f:(fun acc x ->
                 Printf.sprintf "%s %s" acc (Expr.to_string (Var x)) ) )
            (Cmd.to_string action) ) ;
      Printf.printf "\n\n%!" ) ;
  Printf.printf "--\n%!" ;
  t

let positive_actions (params : Parameters.t) (phys : Cmd.t)
    (fvs : (string * int) list) (inpkt : Packet.t) (outpkt : Packet.t) :
    (string * ((string * int) list * int * Cmd.t) list) list * StringSet.t =
  let open Cmd in
  let phys =
    Packet.to_assignment inpkt %:% phys |> CompilerOpts.optimize fvs
  in
  let diff_vars =
    StringSet.(
      inter (of_list @@ fsts fvs) (of_list @@ Packet.diff_vars inpkt outpkt))
  in
  let table_actions = Cmd.get_tables_actions phys in
  let has acts = not (List.is_empty acts) in
  ( List.filter_map table_actions ~f:(fun (table, acts) ->
        let positives =
          List.filter_mapi acts ~f:(fun act_id (_, act_params, act) ->
              let act_vars = assigned_vars act in
              let t =
                if StringSet.are_disjoint diff_vars act_vars then false
                else
                  let map, _ =
                    ConstantProp.propogate_cmd StringMap.empty act
                  in
                  StringMap.fold map ~init:true ~f:(fun ~key ~data acc ->
                      if acc then
                        match Packet.get_val_opt outpkt key with
                        | None -> acc
                        | Some v ->
                            (* every input variable is existentially
                               quantified, unsound but complete *)
                            let unknowns = fsts @@ Expr.frees `Var data in
                            let exp = Expr.holify ~f:Fn.id unknowns data in
                            let test = Test.(Value v %=% exp) in
                            Prover.is_sat params test
                      else acc )
              in
              Option.some_if t (act_params, act_id, act) )
        in
        Option.some_if (has positives) (table, positives) )
    |> print
  , diff_vars )

let reach_positive_actions params problem in_pkt out_pkt =
  let fvs = Problem.fvs problem in
  let fvs_set = fvs |> fsts |> StringSet.of_list in
  let phys = Problem.phys problem in
  let pos_acts, diff_vars =
    positive_actions params phys fvs in_pkt out_pkt
  in
  let diff_vars = StringSet.inter diff_vars fvs_set in
  let affected_vars =
    List.fold pos_acts ~init:StringSet.empty ~f:(fun acc (_, acts) ->
        List.fold acts ~init:acc ~f:(fun acc (_, _, a) ->
            StringSet.union acc @@ Cmd.assigned_vars a ) )
    |> StringSet.inter fvs_set
  in
  if StringSet.(is_subset diff_vars ~of_:affected_vars) then
    List.bind pos_acts ~f:(fun (table, acts) ->
        List.map acts ~f:(fun a -> (table, a)) )
    |> List.map ~f:(fun (table, _) ->
           match Cmd.get_schema_of_table table phys with
           | Some (keys, _, _) ->
               FastCX.is_reachable `Mask params problem fvs in_pkt table keys
           | None ->
               failwith @@ Printf.sprintf "couldn't find table %s" table )
  else
    failwith
    @@ Printf.sprintf "%s is not a subset of %s"
         (string_of_strset diff_vars)
         (string_of_strset affected_vars)

let rec tables_affecting_keys phys (keys : StringSet.t) =
  let open StringSet in
  let open Cmd in
  match phys with
  | Skip | Assume _ -> (keys, empty)
  | Assign (f, e) ->
      if mem keys f then
        (union (remove keys f) (of_list @@ fsts @@ Expr.frees `Var e), empty)
      else (keys, empty)
  | Seq (c1, c2) ->
      let keys2, tables2 = tables_affecting_keys c2 keys in
      let keys1, tables1 = tables_affecting_keys c1 keys2 in
      (keys1, union tables1 tables2)
  | Select (_, cases) ->
      List.map cases ~f:(fun (b, c) ->
          let keys', tables' = tables_affecting_keys c keys in
          (union keys' (of_list @@ fsts @@ Test.vars b), tables') )
      |> List.fold ~init:(empty, empty) ~f:(fun (acc_ks, acc_ts) (ks, ts) ->
             (union acc_ks ks, union acc_ts ts) )
  | Apply t ->
      let some_assigned =
        List.fold t.actions ~init:(assigned_vars t.default)
          ~f:(fun acc (_, _, a) -> union acc (assigned_vars a))
      in
      if are_disjoint some_assigned keys then (keys, empty)
      else
        let all_assigned =
          List.fold t.actions ~init:(assigned_vars t.default)
            ~f:(fun acc (_, _, a) -> inter acc (assigned_vars a))
        in
        let keys' =
          union
            (of_list @@ fsts @@ free_keys t.keys)
            (diff keys all_assigned)
        in
        (keys', singleton t.name)

let rec tables_affected_by_keys phys keys =
  let open StringSet in
  let open Cmd in
  match phys with
  | Skip | Assume _ -> (keys, empty)
  | Assign (f, e) ->
      if mem keys f then
        (union (remove keys f) (of_list @@ fsts @@ Expr.frees `Var e), empty)
      else (keys, empty)
  | Seq (c1, c2) ->
      let keys1, tables1 = tables_affected_by_keys c1 keys in
      let keys2, tables2 = tables_affected_by_keys c2 keys1 in
      (keys2, union tables1 tables2)
  | Select (_, cases) ->
      List.map cases ~f:(fun (b, c) ->
          let keys', tables' = tables_affected_by_keys c keys in
          (union keys' (of_list @@ fsts @@ Test.vars b), tables') )
      |> List.fold ~init:(empty, empty) ~f:(fun (acc_ks, acc_ts) (ks, ts) ->
             (union acc_ks ks, union acc_ts ts) )
  | Apply t ->
      let some_assigned =
        List.fold t.actions ~init:(assigned_vars t.default)
          ~f:(fun acc (_, _, a) -> union acc (assigned_vars a))
      in
      if are_disjoint (of_list @@ fsts @@ free_keys t.keys) keys then
        (keys, empty)
      else
        let keys' =
          union (of_list @@ fsts @@ free_keys t.keys) some_assigned
        in
        (keys', singleton t.name)

(* let rec defaultify (tables : StringSet.t) c =
 *   match c with
 *   | Seq(c1,c2) -> defaultify tables c1 %:% defaultify tables c2
 *   | Select (typ, cs) -> map_snd cs ~f:(defaultify tables)
 *                         |> mkSelect typ
 *   | Apply t when not (StringSet.mem tables t.name) -> t.default
 *   | _ -> c *)

let feasible_tables phys fvs matches inpkt outpkt =
  (* let classify_vars = StringSet.of_list @@ Match.relevant_keys matches in *)
  let delta =
    StringSet.(
      inter (of_list @@ fsts fvs) (of_list @@ Packet.diff_vars inpkt outpkt))
  in
  let affected_tables = tables_affecting_keys phys delta |> snd in
  let controlable_tables =
    tables_affected_by_keys phys
      (StringSet.of_list @@ Match.relevant_keys matches)
    |> snd
  in
  (* let phys' = defaultify affecting_tables phys |> CompilerOpts.optimize
     fvs in *)
  StringSet.inter affected_tables controlable_tables
  |> StringSet.fold ~init:[] ~f:(fun acc t ->
         acc @ List.return
         @@
         match Cmd.get_schema_of_table t phys with
         | None -> failwith @@ Printf.sprintf "table %s not found" t
         | Some (keys, actions, default) ->
             ( t
             , StringSet.of_list @@ fsts @@ Cmd.free_keys keys
             , List.fold actions ~init:(Cmd.assigned_vars default)
                 ~f:(fun acc (_, _, act) ->
                   Cmd.assigned_vars act |> StringSet.union acc ) ) )

let traces (log_edit : Edit.t) fvs phys inpkt outpkt =
  match log_edit with
  | Del _ -> failwith "unsupported"
  | Add (_, (matches, _, _)) ->
      let delta = StringSet.of_list @@ Packet.diff_vars inpkt outpkt in
      let frees = StringSet.of_list @@ fsts fvs in
      flows phys
        { target_vars= StringSet.inter delta frees
        ; source_keys= StringSet.of_list @@ Match.relevant_keys matches }

let string_of_state (st : t) : string =
  string_of_strset st.target_vars
  |> Printf.sprintf "(%s ----> %s)" @@ string_of_strset st.source_keys

let string_of_trace ((state, trace) : t * (string * int) list) : string =
  Printf.sprintf "%s\n\t%s\n%!" (string_of_state state)
  @@ List.fold trace ~init:"" ~f:(fun acc (table, act) ->
         Printf.sprintf "%s %s.action[%d]" acc table act )

let string_of_traces (traces : (t * (string * int) list) list) : string =
  List.fold traces ~init:"Traces:" ~f:(fun acc trace ->
      Printf.sprintf "%s\n\n%s" acc (string_of_trace trace) )
  |> Printf.sprintf "%s\n%!"

let equal_states state state' =
  StringSet.equal state.target_vars state'.target_vars
  && StringSet.equal state.source_keys state'.source_keys

let equal_traces ((state, trace), (state', trace')) =
  equal_states state state'
  && List.equal
       (fun (tbl, act) (tbl', act') -> String.(tbl = tbl') && act = act')
       trace trace'

let equal_trace_lists (traces : (t * (string * int) list) list)
    (traces' : (t * (string * int) list) list) =
  match List.zip traces traces' with
  | Ok zipped -> List.for_all zipped ~f:equal_traces
  | Unequal_lengths -> false
