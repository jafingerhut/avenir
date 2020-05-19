open Core
open Ast


let add_row_prefix = "?AddRowTo"
let delete_row_prefix = "?delete"
let delete_row_infix = "In"
let which_act_prefix = "?ActIn"

let add_row_hole_name = Printf.sprintf "%s%s" add_row_prefix
let delete_row_hole_name i tbl = Printf.sprintf "%s%d%s%s" delete_row_prefix i delete_row_infix tbl
let which_act_hole_name = Printf.sprintf "%s%s" which_act_prefix

let find_add_row = String.chop_prefix ~prefix:add_row_prefix
let find_delete_row key =
  match String.chop_prefix key ~prefix:delete_row_prefix with
  | None -> None
  | Some idx_tbl ->
     match String.substr_index idx_tbl ~pattern:delete_row_infix with
     | None -> None
     | Some idx ->
        let row_idx = String.prefix idx_tbl idx |> int_of_string in
        let table_name = String.drop_prefix idx_tbl (idx + String.length delete_row_infix) in
        Some (table_name, row_idx)


let delete_hole i tbl = Hole(delete_row_hole_name i tbl, 1)
let add_row_hole tbl = Hole (add_row_hole_name tbl, 1)
let which_act_hole tbl actSize =
  assert (actSize > 0);
  Hole (which_act_hole_name tbl, actSize)

let match_hole_exact tbl x = Printf.sprintf "?%s_%s" x tbl
let match_holes_range tbl x =
  (Printf.sprintf "%s_lo" (match_hole_exact tbl x)
  , Printf.sprintf "%s_hi" (match_hole_exact tbl x))
let match_holes_mask tbl x = (match_hole_exact tbl x
                             , Printf.sprintf "%s_mask" (match_hole_exact tbl x))

let match_holes encode_tag tbl x sz =
  match encode_tag with
  | `Mask ->
     let (hv,hm) = match_holes_mask tbl x in
     mkMask (Var(x, sz)) (Hole (hm,sz)) %=% Hole (hv, sz)
  | `Exact ->
     let h = match_hole_exact tbl x in
     Var(x, sz) %=% Hole (h,sz)

