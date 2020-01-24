open Core
open Ast
open Synthesis
open Util
open Packet

module IntMap = Map.Make(Int)
       
let permute l =
  List.map l ~f:(fun x -> (Random.int (List.length l), x))
  |> List.sort ~compare:(fun (i, _) (j,_) -> compare i j)
  |> List.map ~f:(snd) 
              
let tbl = Printf.sprintf "tbl%d"
    
let rec mk_pipeline varsize =
  let rng = (range_ex 0 (pow 2 varsize)) in
  fun n ->
  if n = 0 then [] else
    (tbl n
    , [("k_" ^tbl n, varsize)]
    , List.fold rng  ~init:[]
        ~f:(fun acc i -> (("x_"^tbl n) %<-% mkVInt (i,varsize)) :: acc)
    , ("x_"^tbl n) %<-% mkVInt (0,varsize)
    ) :: mk_pipeline varsize (n-1)


let rec generate_n_insertions varsize length n generated : edit list =
  if n = 0 then [] else
    let rec loop_keys _ =
      let i = Random.int length + 1 in
      let key = Exact (Random.int (pow 2 varsize), varsize) in
      if List.exists generated ~f:((=) (tbl i, key))
      then loop_keys ()
      else (tbl i, key)
    in
    let (tbl_name, keys) = loop_keys () in
    (tbl_name, ([keys], Random.int (pow 2 varsize)))
    :: generate_n_insertions varsize length (n-1) ((tbl_name, keys)::generated)

let reorder_benchmark varsize length max_inserts =
  let logical_pipeline = mk_pipeline varsize length in
  let physical_pipeline = permute logical_pipeline in
  let mk_empty_inst acc (name,_,_,_) =    Map.set acc ~key:name ~data:[]  in
  let linst = List.fold logical_pipeline ~init:StringMap.empty ~f:mk_empty_inst in
  let pinst = List.fold logical_pipeline ~init:StringMap.empty ~f:mk_empty_inst in
  let to_cmd line =  List.((line >>| fun t -> Apply t)
                           |> reduce_exn ~f:(%:%)) in
  (* let hints = Some(fun vMap -> (\*[vMap]*\)
   *                 [List.fold ~init:vMap (range_ex 1 (length + 8))
   *                   ~f:(fun acc i ->
   *                     StringMap.set acc ~key:("?AddRowTo" ^ tbl i)
   *                       ~data:(mkVInt(1,1))
   *                 )]
   *               ) in *)
  let hints = Some (List.return) in
  (* let hints = None in *)
  let log = to_cmd logical_pipeline in
  let phys = to_cmd physical_pipeline in
  let insertion_sequence = generate_n_insertions varsize length max_inserts [] in
  (* let rec all_paths i =
   *   if i = 0 then [[]] else
   *     liftL2 mkCons (range_ex 0 4) (all_paths (i-1))
   * in *)
  (* (\* let hints_map =
   *  *   all_paths length
   *  *   |> List.fold ~init:StringMap.empty
   *  *        ~f:( fun acc actSeq ->
   *  *             List.fold_right actSeq ~init:acc
   *  *               ~f:(fun i acc actId ->
   *  *                 StringMap.set acc ~key:(tbl i)
   *  *                   ~data:(mkVInt(actId, 4))))
   *  * in *\)
   * let hints h = Some h in *)
  let fvs = range_ex 1 (length + 1)
            |> List.map ~f:(fun i ->
                   [("k_" ^tbl i, 32)
                   ; (symbolize("k_" ^tbl i), 32)
                   ; (symbolize("x_" ^tbl i), 32)
                   (* ; ("?ActIn"^tbl i, 8) *)
                 ])
            |> List.join
  in
  let rec run_experiment i seq linst pinst =
    match seq with
    | [] -> []
    | edit::edits ->
       let (totalt,checkt,checkn, searcht, searchn, wpt,lwpt,pwpt,sizes,_)  =
         synthesize_edit ~gas:1 ~fvs ~hints log phys linst pinst edit in
       (i, totalt, checkt, checkn, searcht, searchn, wpt,lwpt,pwpt, sizes)
       :: run_experiment (i + 1) edits (apply_edit linst edit) (apply_edit pinst edit)
  in
  let data = run_experiment 0 insertion_sequence linst pinst in
  let mean ds = List.fold ds ~init:0 ~f:((+)) / List.length ds in
  let max_l ds = List.fold ds ~init:0 ~f:(max) in
  let min_l ds = List.fold ds ~init:(max_l ds) ~f:(min) in
  Printf.printf "size,time,check_time,num_z3_calls_check,model_search_z3_time,num_z3_calls_model_search,search_wp_time,check_log_wp_time,check_phys_wp_time,mean_tree_size,max_tree_size,min_tree_size\n";
  List.iter data ~f:(fun (i,t,c,cn,s,sn,wpt,lwpt, pwpt,sizes) ->
      Printf.printf "%d,%f,%f,%d,%f,%d,%f,%f,%f,%d,%d,%d\n"
        i (Time.Span.to_ms t)
        (Time.Span.to_ms c) cn
        (Time.Span.to_ms s) sn
        (Time.Span.to_ms wpt)
        (Time.Span.to_ms lwpt)
        (Time.Span.to_ms pwpt)
        (mean sizes)
        (max_l sizes)
        (min_l sizes)
    )
