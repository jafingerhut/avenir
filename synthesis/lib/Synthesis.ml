open Core
open Ast
open Semantics
open Graph
open Prover
open Manip


(* Computes the trace between two programs *)
let find_trace (graph:graph) (in_pkt : Packet.t) (out_pkt : Packet.t) =
  let in_loc  = Packet.get_val in_pkt  "loc" in
  let out_loc = Packet.get_val out_pkt "loc" in
  let all_paths_to_pkt = get_all_paths_between graph [] in_loc out_loc in
  (* let _ = Printf.printf "ALL PATHS from %d to %d ;\n" in_loc out_loc;
   *         List.iter all_paths_to_pkt ~f:(fun path ->
   *             Printf.printf "\t[ ";
   *             List.iter path ~f:(Printf.printf "%d ");
   *             Printf.printf "]\n%!")          
   * in *)
  List.fold all_paths_to_pkt ~init:None
    ~f:(fun acc rev_path ->
      match acc with
      | Some _ -> acc
      | None ->
         let path_expr = get_program_of_rev_path graph rev_path in
         let condition = Packet.to_test out_pkt in
         let wp_of_path = wp path_expr condition in
         (* let _ = Printf.printf "wp(%s, %s) = %s\n%!"
          *           (string_of_expr path_expr)
          *           (string_of_test condition)
          *           (string_of_test wp_of_path) in *)
         if wp_of_path = False
         then None
         else Some wp_of_path
    )
   

(** Solves the inner loop of the cegis procedure. *)
let get_one_model (pkt : Packet.t) (logical : expr) (real : expr) : Z3.Model.model =
  let pkt',log_trace = trace_eval logical pkt in
  let log_graph = make_graph logical in
  let log_trace_expr = get_program_of_rev_path log_graph (List.rev log_trace) in 
  let real_graph = make_graph real in
  match find_trace real_graph pkt pkt' with
  | None -> failwith "Cannot implement logical network in real network : No path"
  | Some real_wp ->
     let condition = wp log_trace_expr (Packet.to_test pkt') %=>% real_wp in
     match checkModel condition with
     | None -> failwith "Cannot implement logical network in real network : No model"
     | Some model -> model

(** solves the inner loop **)
let inner_cegis_loop (_ : expr) (_ : expr) =
  failwith "?"

  
