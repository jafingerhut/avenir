open Core
open Ast
open Util

type t = value StringMap.t

let empty = StringMap.empty

let to_string (p : t) =
  (StringMap.fold ~f:(fun ~key:k ~data:v acc -> acc ^ k ^ "=" ^ (string_of_value v) ^ "\n") p ~init:"(") ^ ")\n"

let set_field (pkt : t) (field : string) (v : value) : t  =
  (* Printf.printf "Setting %s to %s;\n" (field) (string_of_value v); *)
  StringMap.set pkt ~key:field ~data:v

let get_val_opt (pkt : t) (field : string) : value option =
  StringMap.find pkt field

let get_val (pkt : t) (field : string) : value =
  match get_val_opt pkt field with
    | None -> failwith ("UseBeforeDef error " ^ field ^ " packet is " ^ to_string pkt)
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

let to_test ?random_fill:(random_fill=false)  ~fvs (pkt : t) =
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

let of_smt_model (lst : (Z3.Smtlib.identifier * Z3.Smtlib.term) list) =
  let name_vals : (string * value) list =
    (List.map lst ~f:(fun (Id id, x) ->
         let id = match String.index id '@' with
           | None -> id
           | Some index -> String.drop_prefix id index in
         match x with
         | Z3.Smtlib.BitVec (n, w) -> let value =
                                     Int (Bigint.of_int n, w) in id, value
         | Z3.Smtlib.BigBitVec (n, w) -> let value =
                                        Int (n, w) in id, value
         | Z3.Smtlib.Int i -> let value =
                             Int (Bigint.of_int i, Int.max_value) in id, value
         | _ -> raise (Failure "not a supported model")))
  in
  StringMap.of_alist_exn name_vals

let to_assignment (pkt : t) =
  StringMap.fold pkt ~init:Skip
    ~f:(fun ~key ~data acc -> (%:%) acc @@ key %<-% Value data)

let remake ?fvs:(fvs = None) (pkt : t) : t =
  (* let fvs = None in *)
  match fvs with
  | None -> pkt
  | Some fvs ->
     List.fold fvs ~init:empty
       ~f:(fun acc (var_nm, sz) ->
         match get_val_opt pkt var_nm with
         | Some v ->
            (* Printf.printf "Found %s setting it to %s\n%!" var_nm (string_of_value v); *)
            StringMap.set acc ~key:var_nm ~data:v
         | None ->
            (* Printf.printf "Missed %s setting it to random value\n%!" var_nm; *)
            let top = (pow 2 sz) - 1 |> Float.of_int  in
            let upper = Float.(top * 0.9 |> to_int) |> max 1 in
            let lower = Float.(top * 0.1 |> to_int) in
            StringMap.set acc ~key:var_nm
              ~data:(mkInt(lower + Random.int upper, sz))
       )

let restrict_packet (fvs : (string * size) list) pkt =
  StringMap.filter_keys pkt ~f:(fun k -> List.exists fvs ~f:(fun (v,_) -> k = v))

let equal ?fvs:(fvs = None) (pkt:t) (pkt':t) =
  match fvs with
  | None -> StringMap.equal (=) pkt pkt'
  | Some fvs ->
     StringMap.equal (=) (restrict_packet fvs pkt) (restrict_packet fvs pkt')

let extract_inout_ce (model : t) : (t * t) =
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
  StringMap.of_alist_exn assoc

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


(** inherited from Core.Map *)
let fold = StringMap.fold
let to_expr_map = StringMap.map ~f:(fun v -> Value v)
