open Core
open Avenir
open Ast

let testable_string (type a) (f : a -> string) (eq : a -> a -> bool) =
  Alcotest.testable (Fmt.of_to_string f) (eq)

let expr = testable_string string_of_expr Stdlib.(=)
let same_expr = Alcotest.(check expr) "same expr"

let test = testable_string string_of_test Stdlib.(=)
let same_test = Alcotest.(check test) "same test"

let cmd = testable_string sexp_string_of_cmd Stdlib.(=)
let same_cmd = Alcotest.(check cmd) "same cmd"

let packet = testable_string Packet.to_string Packet.equal
let same_packet = Alcotest.(check packet) "same packet"

let vv_stringmap = testable_string
                     (Util.string_of_strmap ~to_string:(fun (v1,v2) -> Printf.sprintf "(%s, %s)" (string_of_value v1) (string_of_value v2)))
                     (Util.StringMap.equal (fun (v1,v2) (v1',v2') -> veq v1 v1' && veq v2 v2'))
let same_vv_stringmap = Alcotest.(check vv_stringmap) "same value^2 string map"
(* let packet = testable_string string_of_map (Util.StringMap.equal veq)
 * let same_packet = Alcotest.(check packet) "same packet" *)

let model = testable_string Model.to_string Model.equal
let same_model = Alcotest.(check model) "same model"

let stringlist = testable_string (List.fold ~init:"" ~f:(Printf.sprintf "%s %s")) (Stdlib.(=))
let same_stringlist = Alcotest.(check stringlist) "same string list"

let stringset = testable_string (Util.string_of_strset) (Util.StringSet.equal)
let same_stringset = Alcotest.(check stringset) "same string set"

let edits =
  testable_string
    (Edit.list_to_string)
    (fun es es' -> String.(Edit.list_to_string es =  Edit.list_to_string es'))

let same_edits = Alcotest.(check edits) "same edits"
