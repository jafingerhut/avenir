open Core
open Ast
open Util

module StringMap = Map.Make (String)

type t = value StringMap.t

type located = t * (int option)


let string__packet (p : t) =
  (StringMap.fold ~f:(fun ~key:k ~data:v acc -> acc ^ k ^ "=" ^ (string_of_value v) ^ "\n") p ~init:"(") ^ ")\n"

let set_field (pkt : t) (field : string) (v : value) : t  =
  (* Printf.printf "Setting %s to %s;\n" (field) (string_of_value v); *)
  StringMap.set pkt ~key:field ~data:v

let get_val_opt (pkt : t) (field : string) : value option =
  StringMap.find pkt field

let get_val (pkt : t) (field : string) : value =
  match get_val_opt pkt field with
    | None -> failwith ("UseBeforeDef error " ^ field ^ " packet is " ^ string__packet pkt)
    | Some v -> v

let rec set_field_of_expr_opt (pkt : t) (field : string) (e : expr) : t option =
  let open Option in
  if has_hole_expr e then
    failwith @@ Printf.sprintf "[PacketHole] Tried to assign %s <- %s" field (string_of_expr e)
  else
    let binop op e e'=
      set_field_of_expr_opt pkt field e >>= fun pkt ->
      get_val_opt pkt field >>= fun v ->
      set_field_of_expr_opt pkt field e' >>= fun pkt' ->
      get_val_opt pkt' field >>| fun v' ->
      set_field pkt field (op v v')
  in
  match e with
  | Value v -> Some (set_field pkt field v)
  | Var (x,_) ->  get_val_opt pkt x >>| set_field pkt field
  | Hole _ -> failwith "impossible"
  | Cast (i,e) ->
     set_field_of_expr_opt pkt field e >>| fun pkt_e ->
     set_field pkt field @@ cast_value i @@ get_val pkt_e field
  | Slice {hi;lo;bits} ->
     set_field_of_expr_opt pkt field bits >>| fun pkt_bits ->
     set_field pkt field @@ slice_value hi lo @@ get_val pkt_bits field
  | Plus  (e, e') -> binop add_values e e'
  | SatPlus (e,e') -> binop sat_add_values e e'
  | Times (e, e') -> binop multiply_values e e'
  | Minus (e, e') -> binop subtract_values e e'
  | SatMinus (e,e') -> binop sat_subtract_values e e'
  | Mask (e,e') -> binop mask_values e e'
  | Xor (e,e') -> binop xor_values e e'
  | BOr (e,e') -> binop or_values e e'
  | Shl (e,e') -> binop shl_values e e'
  | Concat (e,e') -> binop concat_values e e'


let init_field_to_random bound pkt (f,sz) =
  set_field pkt f (Int (Random.int (max bound 1) |> Bigint.of_int_exn, sz))

let rec init_field_to_value_in (values : value list) pkt (f, sz) =
  match values with
  | [] -> init_field_to_random 10000000 pkt (f,sz)
  | _ ->
     let i = Random.int (List.length values) in
     let vi = List.nth_exn values i in
     if size_of_value vi = sz then
       set_field pkt f vi
     else
       init_field_to_value_in (List.filter values ~f:(fun x -> x <> vi)) pkt (f, sz)

let to_test ?fvs:(fvs = []) ?random_fill:(random_fill=false) (pkt : t) =
  (* let random_fill = false in *)
  List.fold fvs ~init:True
    ~f:(fun acc (x,sz) ->
      acc %&% (
          match StringMap.find pkt x with
          | None ->
             if random_fill then
               Var(x,sz) %=% mkVInt(Random.int (pow 2 sz),sz)
             else
               Var(x,sz) %=% Var(x^"_symb", sz)
          | Some v ->
             Var(x, sz) %=% Value(v)))


let test_of_wide ?fvs:(fvs = []) wide =
  StringMap.fold wide ~init:True
    ~f:(fun ~key ~data:(lo,hi,sz) test ->
      if key <> "loc" && List.exists fvs ~f:(fun (x,_) -> key = x) then
        (if lo = hi
         then Var (key, sz) %=% mkVInt(lo,sz)
         else (mkVInt(lo, sz) %<=% Var(key,sz)) %&% (Var (key, sz) %<=% mkVInt(hi,sz))
        ) %&% test
      else ( test ))

let to_assignment (pkt : t) =
  StringMap.fold pkt ~init:Skip
    ~f:(fun ~key ~data acc -> (%:%) acc @@ key %<-% Value data)

let empty = StringMap.empty



let make ?fvs:(fvs = None) (store : value StringMap.t) : t =
  (* let fvs = None in *)
  match fvs with
  | None -> store
  | Some fvs ->
     List.fold fvs ~init:empty
       ~f:(fun acc (var_nm, sz) ->
         match StringMap.find store var_nm with
         | Some v ->
            (* Printf.printf "Found %s setting it to %s\n%!" var_nm (string_of_value v); *)
            StringMap.set acc ~key:var_nm ~data:v
         | None ->
            (* Printf.printf "Missed %s setting it to ranodm value\n%!" var_nm; *)
            let top = (pow 2 sz) - 1 |> Float.of_int  in
            let upper = Float.(top * 0.9 |> to_int) |> max 1 in
            let lower = Float.(top * 0.1 |> to_int) in
            StringMap.set acc ~key:var_nm
              ~data:(mkInt(lower + Random.int upper, sz))
       )


let restrict_packet fvs pkt =
  StringMap.filter_keys pkt ~f:(fun k -> List.exists fvs ~f:(fun (v,_) -> k = v))


let equal ?(fvs = None) (pkt:t) (pkt':t) =
  match fvs with
  | None -> StringMap.equal (=) pkt pkt'
  | Some fvs ->
     StringMap.equal (=) (restrict_packet fvs pkt) (restrict_packet fvs pkt')


let subseteq_aux smaller bigger =
  StringMap.fold smaller ~init:true ~f:(fun ~key ~data acc ->
      if not acc then acc
      else
        match StringMap.find bigger key with
        | None -> false
        | Some big_data -> acc && big_data = data
    )

let subseteq ?(fvs = None) (smaller:t) (bigger:t) =
  match fvs with
  | None -> subseteq_aux smaller bigger
  | Some fvs -> subseteq_aux (restrict_packet fvs smaller) (restrict_packet fvs bigger)




let generate ?bound:(bound=10000000) ?values:(values=([] : value list))  (vars : (string * size) list) =
  match values with
  | [] ->
    List.fold vars ~init:empty ~f:(init_field_to_random bound)
  | _ ->
    List.fold vars ~init:empty ~f:(init_field_to_value_in values)

let is_symbolic = String.is_suffix ~suffix:"_SYMBOLIC"
let symbolize str =
  if is_symbolic str then str else
    str ^ "_SYMBOLIC"
let unsymbolize = String.substr_replace_all ~pattern:"_SYMBOLIC" ~with_:""

let from_CE (model : value StringMap.t) : t =
  StringMap.fold model ~init:empty
    ~f:(fun ~key ~data pkt ->
      let key = String.split key ~on:('!') |> List.hd_exn in
      if is_symbolic key && not(String.is_prefix key ~prefix:"?ActIn")
      then pkt
      else
        let key = unsymbolize key in
        set_field pkt key data)

let un_SSA (pkt : t) : t =
  StringMap.fold pkt ~init:empty
    ~f:(fun ~key ~data acc_pkt ->
      match String.rsplit2 key ~on:'$' with
      | None ->
         StringMap.set acc_pkt ~key:(key) ~data
      | Some (key', i) ->
         if int_of_string i = 0
         then
           StringMap.set acc_pkt ~key:(key') ~data
         else acc_pkt
    )

let extract_inout_ce (model : value StringMap.t) : (t * t) =
  StringMap.fold model
    ~init:((empty, empty), StringMap.empty)
    ~f:(fun ~key ~data (((in_pkt, out_pkt), counter) as acc) ->
      if String.is_substring key ~substring:"phys_" then acc else
      match String.rsplit2 key ~on:'$' with
      | None -> Printf.sprintf "Couldn't find index for %s" key |> failwith
      | Some (v, idx_s) ->
         let idx = int_of_string idx_s in
         let in_pkt' = if idx = 0 then
                         set_field in_pkt v data
                       else in_pkt in
         let out_pkt', counter' =
           match StringMap.find counter v with
           | Some idx' when idx' >= idx ->
              (out_pkt, counter)
           | _ ->
              (set_field out_pkt v data,
               StringMap.set counter ~key:v ~data:idx) in
         ((in_pkt', out_pkt'), counter')
    )
  |> fst



let mk_packet_from_list (assoc : (string * value) list) : t =
  List.fold assoc ~init:empty
    ~f:(fun pkt (f, v) -> set_field pkt f v)

let diff_vars (pkt : t) (pkt' : t) : string list =
  let is_drop pkt = Option.(StringMap.find pkt "standard_metadata.egress_spec" >>| (=) (mkInt(0,9))) in
  let alternate_drop =
    match is_drop pkt, is_drop pkt' with
    | Some dropped, Some dropped' ->
       dropped && not dropped'
       || dropped' && not dropped
    | _ -> false
  in
  if alternate_drop
  then
    ["standard_metadata.egress_spec"]
  else
  let diff_map = StringMap.merge pkt pkt'
    ~f:(fun ~key:_ -> function
      | `Both (l,r) when veq l r -> None
      | `Left v | `Right v | `Both(_,v) -> Some v)
  in
  StringMap.keys diff_map




let restrict (pkt : t) (vars : StringSet.t) : t =
  StringMap.filter_keys pkt ~f:(StringSet.mem vars)
