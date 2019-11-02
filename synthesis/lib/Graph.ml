open Core
open Ast
open Manip
open Util

module Int = struct
  type t = int
  let compare = compare
  let sexp_of_t = sexp_of_int
  let t_of_sexp = int_of_sexp
end
   
module IntMap = Map.Make (Int)

type graph = (((test * cmd) list) IntMap.t) IntMap.t
type path = int list

let string_of_graph (g : graph) =
  IntMap.fold
    ~f:(fun ~key:k1 ~data:n1 acc1 -> 
        acc1 ^ 
	IntMap.fold ~f:(fun ~key:k2 ~data:n2 acc2 -> 
	    acc2 ^ (string_of_int k1) ^ "->" ^ 
     (List.fold_left ~f:(fun acc3 (t,e) ->
          (acc3 ^ "(" ^ (string_of_test t) ^ "," ^ (string_of_cmd e) ^ ")") ) ~init:"" n2) ^ "->" ^
     (string_of_int k2) ^ "\n") n1 ~init:"") g ~init:""					                  
    
let to_dot (g : graph) =
	let dot =
  ((IntMap.fold
    ~f:(fun ~key:k1 ~data:n1 acc1 -> 
        acc1 ^ 
	IntMap.fold ~f:(fun ~key:k2 ~data:n2 acc2 -> 
	    acc2 ^ ("   " ^ string_of_int k1) ^ "->" ^ (string_of_int k2) ^ "  [label=\"" ^
     (List.fold_left ~f:(fun acc3 (t,e) -> (acc3 ^ "(" ^ (string_of_test t) ^ "," ^ (string_of_cmd e) ^ ")") ) ~init:"" n2) ^ "\"]" ^
      "\n") n1 ~init:"") g ~init:"digraph g {\n") ^ "}") in
	let name = "output.viz" in
	let file = Out_channel.create name in
    Out_channel.output_string file dot;
		Out_channel.flush file;
		ignore( Sys.command (Printf.sprintf "dot %s -Tpng -o output.png && rm %s" name name) ) ;;
  
		
let string_of_path (p : path) =
  List.fold_left ~f:(fun acc e -> acc ^ "->" ^ (string_of_int e)) p ~init:""

let (%.) f g x = f (g x)
             
let rec split_test_on_loc test =
  match test with
  | Or _ ->
    failwith
      ("malformed test, || not allowed in if statement, please make a separate case ("
       ^ (string_of_test test) ^")")
  | True -> (None, True)
  | False -> (None, False)
  | LocEq l -> (Some l, True)
  | Eq (v, v') -> (None, mkEq v v')
  | Lt (v, v') -> (None, mkLt v v')
  | Neg _ -> (None, test)
  | And (a, b) ->
     let loc_opt_a, test_a = split_test_on_loc a in
     let loc_opt_b, test_b = split_test_on_loc b in
     let test = mkAnd test_a test_b in
     match loc_opt_a, loc_opt_b with
     | None, None -> (None, test)
     | None, loc_opt | loc_opt, None -> (loc_opt, test)
     | Some l, Some l' ->
        if l = l' then (Some l , test)
        else failwith "malformed test, cannot have multiple locs in if statement"

let rec split_cmd_on_loc (cmd:cmd) : (cmd * int option) =
  match cmd with
  | While _ -> failwith "cannot handle while nested under select"
  | Select _ -> failwith "Cannot handle nested selects"
  | SetLoc l -> (Skip, Some l)
  | Assign _
    | Skip
    | Assert _
    | Assume _
    | Apply _ -> (cmd, None)
  | Seq (p, q) ->
     let (cmd_p, loc_p) = split_cmd_on_loc p in
     let (cmd_q, loc_q) = split_cmd_on_loc q in
     let cmd = mkSeq cmd_p cmd_q in
     match loc_p, loc_q with
     | None, None -> (cmd, None)
     | None,  l_opt | l_opt, None -> (cmd, l_opt)
     | Some _, Some lq ->
        (* Take the latter update *)
        (cmd, Some lq)


let normalize_selects (ss : (test * cmd) list) : (test * cmd) list =
  List.fold ss ~init:[] ~f:(fun ss' (test, cmd) ->
      List.fold (dnf test) ~init:ss' ~f:(fun ss' test ->
          (test, cmd) :: ss'
        )
    )

let ordered_selects ss =
  List.fold ss ~init:([], True)
    ~f:(fun (prev_cases, prev_conds) (cond, act) ->
        let loc_opt, _ = split_test_on_loc cond in
        match loc_opt with
        | None -> failwith ("[MALFORMED TEST ERROR] No Location found in " ^ string_of_test cond)
        | Some loc ->
          (prev_cases @ [(cond %&% (remove_locs_neq loc prev_conds), act)]
          , prev_conds %&% !%(cond))
      )
  |> fst
       
let rec get_selects (e : Ast.cmd) =
  match e with
  | Skip | SetLoc _ | Assign _ | Assert _ | Assume _ | Apply _ -> []
  | While (_, body) -> get_selects body
  | Seq (firstdo, thendo) -> get_selects firstdo @ get_selects thendo
  | Select (styp, ss) ->
    let process ss =
      List.fold_left ss ~init:[] ~f:(fun ss' (test, act) ->
          let src, test' = split_test_on_loc test in
          let act', dst = split_cmd_on_loc act in
          match src, dst with
          | None, _ | _, None ->
            if test = False then
              ss'
            else
              failwith ("could not find location for "
                        ^ sexp_string_of_test test ^ " -> "
                        ^ sexp_string_of_cmd act ^ " in select statement "
                        ^ string_of_cmd e
                       )
          | Some s, Some d ->
            (s, test', act', d) :: ss'
        )
    in
    (match styp with
    | Partial
    | Total 
      -> process ss
    | Ordered
      -> 
      (* Printf.printf "------------ADDING SELECTS-----------\nORDERED:\n%s\n%!\nPARTIAL:\n%s\n%!\n"
       *   (string_of_cmd (Select (Ordered, ss)))
       *   (string_of_cmd (Select (Partial, fst ordered_selects)));
       *   (\* (string_of_cmd (Select (Partial, normalize_selects (fst ordered_selects)))); *\) *)
      process (ordered_selects ss)
    ) |> dedup
         
      

let add_edge graph (src,test,act,dst) =
  (* Printf.printf "[GRAPH] add_edge FROM:%d TO:%d IF:%s DO:%s\n%!"
   *   src
   *   dst
   *   (string_of_test test)
   *   (string_of_cmd act); *)
  IntMap.update graph src
    ~f:(fun x -> IntMap.update (Option.value ~default:IntMap.empty x) dst
                   ~f:(fun y -> ((test, act) :: Option.value ~default:[] y) |> dedup))
  
let make_graph (e : Ast.cmd) : graph =
  let selects = get_selects e in
  List.fold selects ~init:IntMap.empty ~f:add_edge


let get_neighbors (graph:graph) location =
  match IntMap.find graph location with
  | None -> IntMap.empty
  | Some nbrs -> nbrs
  

let get_all_paths_between (graph:graph) (current:int) (final:int) : path list =
  let rec rec_get_all_paths_between (graph:graph) (rev_path:path) (current:int) (final:int) : path list =
      if current = final then (* reached destination *)
        [current :: rev_path]
      else if List.mem rev_path current ~equal:(=) then (* Found a loop *)
        [] (* destroy the current path *)
      else
        let nbrs = get_neighbors graph current |> IntMap.keys in
        List.fold nbrs ~init:[] ~f:(fun paths nbr ->
            (rec_get_all_paths_between graph (current :: rev_path) nbr final)
            @ paths
          )
  in 
  rec_get_all_paths_between graph [] current final

let all_locations graph : int list =
  let init = IntMap.keys graph in
  let f acc current = 
    let nbrs = get_neighbors graph current |> IntMap.keys in
    acc @ nbrs
    |> List.dedup_and_sort ~compare
  in
  List.fold init ~init ~f

let get_all_paths graph =
  let nodes = all_locations graph in
  let all_endpoints = List.cartesian_product nodes nodes in
  concatMap all_endpoints ~c:(@)
    ~f:(fun (src, dst) ->
        get_all_paths_between graph src dst
      )

let get_edges (graph:graph) src dst =
  Printf.printf "[LOG] looking for edge from %d to %d\n%!" src dst;
  let succs = IntMap.find_exn graph src in
  let edges = IntMap.find_exn succs dst in
  (* let other_conditions = IntMap.fold succs
   *     ~f:(fun ~key ~data others ->
   *         if key = dst then others
   *         else data @ others
   *       )
   * in *)
  if List.length edges > 1 then
    mkOrdered edges
  else
    concatMap edges ~c:(%:%) ~f:(fun (cond, act) -> Assert cond %:% act)


let rec get_program_of_rev_path graph rev_path : cmd =
  match rev_path with
  | [] 
  | [_] -> Skip
  | after :: before :: rest -> (* path is reversed so packet traveling from before -> after  *)
     let edges = get_edges graph before after in
     get_program_of_rev_path graph (before :: rest) %:% edges     

let diameter (c:cmd) =
  (make_graph c
   |> get_all_paths
   |> List.fold
     ~init:(0)
     ~f:(fun curr_max p ->
         let len = List.length p in
         if len > curr_max then
           len
         else
           curr_max)
  ) - 1
