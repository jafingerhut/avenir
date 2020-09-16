open Core
open Ast
open Packet
open Z3

let force_print = false
let print_debug = false

let debug term =
  if force_print || print_debug then
    let res = Smtlib.term_to_sexp term |> Smtlib.sexp_to_string in
    Printf.eprintf "(assert %s)\n%!" res

let test_str test =
  if false then
    let res = Ast.string_of_test test in Printf.printf "TEST: %s\n%!"res
  else ()

let expr_str test =
  if force_print || print_debug then
    let res = Ast.string_of_expr test in Printf.printf "EXPR: %s"res
  else ()

let quantify expr etyp styp =
  match etyp, styp with
  | `Var, `Valid -> Smtlib.const expr
  | `Hole, `Valid -> failwith "holes not allowed in valid queries"
  | _, `Sat -> Smtlib.const expr

let rec expr_to_term_help expr styp : Smtlib.term =
  match expr with
  | Value (Int (num, sz)) ->
     let num = if Bigint.(num < zero) then Bigint.(Util.max_int sz - num) else num in
     Smtlib.bbv (num) sz
  | Var (v, _) -> quantify v `Var styp
  | Hole (h, _) -> quantify h `Hole styp
  | Cast (i,e) ->
     let sz = size_of_expr e in
     let t = expr_to_term_help e styp in
     if sz > i
     then Smtlib.extract (i-1) 0 t
     else if sz < i
     then Smtlib.concat (expr_to_term_help (mkVInt(0,i-sz))  styp) t
     else t
  | Slice {hi;lo;bits} ->
     let term = expr_to_term_help bits styp in
     Smtlib.extract (hi-1) lo term

  | Plus (e1, e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     Smtlib.bvadd
       (expr_to_term_help e1 styp)
       (expr_to_term_help e2 styp)

  | SatPlus(e1,e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     let t1 = expr_to_term_help e1 styp in
     let t2 = expr_to_term_help e2 styp in
     let sz = size_of_expr e1 in
     let maxt = expr_to_term_help (Value(Int(Util.max_int sz, sz))) styp in
     let bad = Smtlib.(bvugt t2 (bvsub maxt t1)) in
     Smtlib.(ite bad maxt (bvadd t1 t2))


  | Times (e1, e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     Smtlib.bvmul
       (expr_to_term_help e1 styp)
       (expr_to_term_help e2 styp)

  | Minus (e1, e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     Smtlib.bvsub
       (expr_to_term_help e1 styp)
       (expr_to_term_help e2 styp)

  | SatMinus (e1,e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     let t1 = expr_to_term_help e1 styp in
     let t2 = expr_to_term_help e2 styp in
     let sz = size_of_expr e1 in
     let zero = expr_to_term_help (mkVInt(0, sz)) styp in
     let bad = Smtlib.(bvult t1 t2) in
     Smtlib.(ite bad zero (bvsub t1 t2))

  | Mask (e1,e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     let sexp = Smtlib.bvand
                  (expr_to_term_help e1 styp)
                  (expr_to_term_help e2 styp) in
     (* expr_str expr;
      * debug sexp; *)
     sexp
  | Xor (e1,e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     let sexp = Smtlib.bvneg @@
                  Smtlib.bvxnor
                    (expr_to_term_help e1 styp)
                    (expr_to_term_help e2 styp) in
     (* expr_str expr;
      * debug sexp; *)
     sexp
  | BOr (e1,e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     let sexp = Smtlib.bvor
                  (expr_to_term_help e1 styp)
                  (expr_to_term_help e2 styp) in
     (* expr_str expr;
      * debug sexp; *)
     sexp
  | Shl (e1,e2) ->
     let sexp = Smtlib.bvshl
                  (expr_to_term_help e1 styp)
                  (expr_to_term_help e2 styp) in
     (* expr_str expr;
      * debug sexp; *)
     sexp
  | Concat (e1,e2) ->
       Smtlib.concat
         (expr_to_term_help e1 styp)
         (expr_to_term_help e2 styp)



let rec test_to_term_help test styp : Smtlib.term =
  match test with
  | True -> Smtlib.bool_to_term true
  | False -> Smtlib.bool_to_term false
  | Eq (e1, e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     Smtlib.equals
       (expr_to_term_help e1 styp)
       (expr_to_term_help e2 styp)
  | Le (e1, e2) ->
     if size_of_expr e1 <> size_of_expr e2
     then Printf.printf "%s and %s are differently sized\n%!" (string_of_expr e1) (string_of_expr e2);
     Smtlib.bvule
       (expr_to_term_help e1 styp)
       (expr_to_term_help e2 styp)
  | And (t1, t2) -> Smtlib.and_
                      (test_to_term_help t1 styp)
                      (test_to_term_help t2 styp)
  | Or (t1, t2) -> Smtlib.or_
                     (test_to_term_help t1 styp)
                     (test_to_term_help t2 styp)
  | Impl (t1, t2) -> Smtlib.implies
                       (test_to_term_help t1 styp)
                       (test_to_term_help t2 styp)
  | Iff (t1, t2) -> Smtlib.equals
                      (test_to_term_help t2 styp)
                      (test_to_term_help t1 styp)
  | Neg t -> Smtlib.not_ (test_to_term_help t styp)

let model_to_packet (lst : (Smtlib.identifier * Smtlib.term) list) =
  let name_vals : (string * value) list =
    (List.map lst ~f:(fun (Id id, x) ->
         let id = match String.index id '@' with
           | None -> id
           | Some index -> String.drop_prefix id index in
         match x with
         | Smtlib.BitVec (n, w) -> let value =
                                     Int (Bigint.of_int n, w) in id, value
         | Smtlib.BigBitVec (n, w) -> let value =
                                        Int (n, w) in id, value
         | Smtlib.Int i -> let value =
                             Int (Bigint.of_int i, Int.max_value) in id, value
         | _ -> raise (Failure "not a supported model")))
  in StringMap.of_alist_exn name_vals

let toZ3String test = test_to_term_help test `Sat
                      |> Smtlib.term_to_sexp |> Smtlib.sexp_to_string

let expr_to_term e styp d =
  if force_print || d
  then (expr_str e; let res = expr_to_term_help e styp in (*debug res;*) res)
  else expr_to_term_help e styp

let test_to_term test styp d =
  if force_print || d
  then (test_str test; let res = test_to_term_help test styp in (*debug res;*) res)
  else test_to_term_help test styp

let vars_to_term vars d =
  let open Smtlib in
  if force_print || d && print_debug
  then begin
      let open List in
      iter vars ~f:(fun (id, i) -> Printf.printf "VAR: %s %d\n%!" id i);
      map vars ~f:(fun (id, i) -> (Id id, BitVecSort i))
    end
  else List.map vars ~f:(fun (id, i) -> (Id id, BitVecSort i))

let sat_prover = Smtlib.make_solver "/usr/bin/z3"
let valid_prover = sat_prover
let shortener = Bishtbl.make ()

let check_sat (params : Parameters.t) (longtest : Ast.test) =
  let open Smtlib in
  (* Printf.printf "Finding model for test of size %d\n%!" (num_nodes_in_test test); *)
  (* Printf.printf "\n%s\n\n%!" (string_of_test test); *)
  if longtest = True then (Some StringMap.empty, Time.Span.zero) else
  if longtest = False then (None, Time.Span.zero) else
  let test = Shortener.shorten shortener longtest in
  if params.debug then assert (longtest = Shortener.unshorten shortener test);
  let vars = vars_to_term (free_vars_of_test test) params.debug in
  let st = Time.now() in
  let holes = holes_of_test test |> List.dedup_and_sort
                ~compare:(fun (idx, _) (idy, _) -> Stdlib.compare idx idy) in
  let () = List.iter holes
             ~f:(fun (id, i) ->
               if force_print || params.debug && print_debug then
                    Printf.eprintf "(declare-const %s (_ BitVec %d))\n%!" id i;
               declare_const sat_prover (Id id) (BitVecSort i)) in
  let term = forall_ vars (test_to_term test `Sat params.debug) in
  let response =
    if force_print || params.debug && print_debug then debug term;
    assert_ sat_prover term;
    if force_print || params.debug && print_debug then Printf.printf " Asserted % dnodes!\n%!" (num_nodes_in_test test);
    check_sat(* _using (ParOr (UFBV, SMT)) *) sat_prover in
  let dur = Time.(diff (now()) st) in
  if params.debug && print_debug then Printf.printf "Got a Result\n%!";
  let model =
    if response = Sat then
      (* let () = Printf.printf "Sat\n%!" in *)
      let model = get_model sat_prover
                  |> model_to_packet
                  |> Shortener.unshorten_model shortener in
      if params.debug && print_debug then
        Printf.printf "MODEL: %s\n%!" (Packet.string__packet model);
      Some model
      else if response = Unknown then
        failwith "UNKNOWN"
      else None
  in reset sat_prover; (model, dur)

let is_sat params test =
  check_sat params test |> fst |> Option.is_some

let check_valid (params : Parameters.t) (longtest : Ast.test)  =
  let open Smtlib in
  (* Printf.printf "Checking validity for test of size %d\n%!" (num_nodes_in_test test); *)
  let test = Shortener.shorten shortener longtest in
  if params.debug then assert (longtest = Shortener.unshorten shortener test);
  (* printf.printf "Test:  %s\n %!" (string_of_test test ); *)
  let vars = free_vars_of_test test
             |> List.dedup_and_sort
                  ~compare:(fun (idx, _) (idy, _) -> Stdlib.compare idx idy) in
  let () =
    List.iter vars
      ~f:(fun (id, i) ->
        if force_print || params.debug && print_debug then
          Printf.printf "(declare-const %s (_ BitVec %d))\n%!" id i;
        declare_const valid_prover (Id id) (BitVecSort i)) in
  let st = Time.now() in
  let term = not_ (test_to_term test `Valid params.debug) in
  let response =
    if force_print || params.debug && print_debug then debug term;
    assert_ valid_prover term;
    check_sat_using QFBV valid_prover in
  let dur = Time.(diff (now()) st) in
  let model =
    match response with
    | Sat -> get_model valid_prover
             |> model_to_packet
             |> Shortener.unshorten_model shortener
             |> Some
    | Unsat ->  None
    | Unknown -> failwith "response unknown"
  in
  reset valid_prover;
  (model, dur)


let is_valid params test =
  check_valid params test |> fst |> Option.is_none

let cache = ref @@ QAbstr.make ()

let rec restriction_cegis ~gas (params : Parameters.t) (restriction : test option) (query : test) quantified_vars : test option option =
  if gas <= 0 then
    None
  else
    let restr_test = Option.value restriction ~default:True in
    if params.debug then Printf.printf "RESTRICTION: %s\n%!" (string_of_test restr_test);
    match check_valid params (restr_test %=>% query) with
    | None, _ -> Some (restriction)
    | Some m, _ ->
       let restr_test' =
         List.fold quantified_vars ~init:restr_test
           ~f:(fun acc var ->
             acc %&%
               match StringMap.find m var with
               | None ->
                  if params.debug then Printf.printf "Couldn't find %s in model\n%!" var;
                  True
               | Some v -> Var(var, size_of_value v) %<>% Value v) in
       restriction_cegis ~gas:(gas - 1) params (Some restr_test') query quantified_vars


let check_valid_cached (params : Parameters.t) (test : Ast.test) =
  (* let params = {params with debug = true} in *)
  let st = Time.now () in
  let (cache', res) = QAbstr.cache_check params !cache test in
  cache := cache';
  match res with
  | `HitAbs ->
     if params.debug then Printf.printf "\tCache_hit after %fms!\n%!"
       (Time.(diff (now()) st |> Span.to_ms));
     (None, Time.(diff (now ()) st))
  | `Hit _ -> (None, (Time.(diff (now ()) st)))
  | `Miss test ->
     if params.debug then Printf.printf "\tCouldn't abstract from %d previous tests : %d nodes!\n%!" (List.length !cache.seen) (num_nodes_in_test test);
     let dur' = Time.(diff (now()) st) in
     if params.debug then Printf.printf "Querying\n%!";
     let (m , dur) = check_valid params test in
     if params.debug then Printf.printf "Queried\n%!";
     if Option.is_none m then
       let () = if params.debug then Printf.printf "successfully!\n%!" in
       cache := QAbstr.add_test test !cache;
     else
       if params.debug then Printf.printf "Unsuccessfully\n%!";

     (m, Time.Span.(dur + dur'))
  | `AddAbs (qvars,query) ->
     if params.debug then Printf.printf "\tChecking abstraction from %d previous tests and %d abstractions!\n%!" (List.length !cache.seen) (List.length !cache.generals);
     (* if params.debug then Printf.printf "ABSTRACTION: %s\n" (string_of_test query); *)
     let m = restriction_cegis ~gas:2 params None query qvars  in
     let dur' = Time.(diff (now()) st) in
     match m with
     | None ->
        (*Couldn't find a restriction to make it valid *)
        if params.debug then Printf.printf "\tAbstraction Failed\n%!";
        Interactive.pause params.interactive;
        (* if params.debug then Printf.printf "\t%s\n%!" (string_of_test q); *)
        let (m , _) = check_valid params test in
        let dur' = Time.(diff (now()) st) in
        (m, dur')
     | Some restriction -> (*FOund a restriction to make it valid*)
        if params.debug then Printf.printf "\tAbstraction successful\n%!";
        Interactive.pause params.interactive;
        cache := QAbstr.add_abs ~query ~restriction test !cache;
        (None, dur')


let check_min (params : Parameters.t) (test : Ast.test) =
  let open Smtlib in
  let st = Time.now() in
  let vars = List.map (free_vars_of_test test)
      ~f:(fun (id, i) -> (Id id, BitVecSort i)) in
  let holes = holes_of_test test |> List.dedup_and_sort
                ~compare:(fun (idx, _) (idy, _) -> Stdlib.compare idx idy) in
  let constraints =
    List.fold holes
      ~init:[]
      ~f:(fun acc (hi,_) ->
          if String.is_suffix hi ~suffix:"_hi"
          then
            let hivar = String.rev hi
                        |> String.substr_replace_first
                          ~pattern:"ih_" ~with_:""
                        |> String.rev in
            List.fold holes
              ~init:acc
              ~f:(fun acc' (lo, sz) ->
                  if String.is_suffix lo ~suffix:"_lo"
                  then
                    let lovar = String.rev lo
                                |> String.substr_replace_first
                                  ~pattern:"ol_" ~with_:""
                                |> String.rev in
                    if hivar = lovar
                    then acc @ [(Minus(Hole(hi,sz), Hole(lo,sz)))]
                    else acc'
                  else acc'
                )
          else acc
        ) in
  let ranges = List.map constraints
      ~f:(fun e -> expr_to_term e `Sat params.debug) in
  let () = List.iter holes
      ~f:(fun (id, i) -> declare_const sat_prover (Id id) (BitVecSort i)) in
  let term = (test_to_term test `Sat params.debug) in
  let response = assert_ sat_prover (forall_ vars term);
    List.iter ranges ~f:(fun t -> minimize sat_prover t);
    check_sat_using (UFBV : tactic) sat_prover in
  let dur = Time.(diff (now()) st) in
  let model =
    if response = Sat then
      Some (model_to_packet (get_model sat_prover))
    else None
  in reset sat_prover; (model, dur)


let is_valid_cached params test =
  check_valid_cached params test |> fst |> Option.is_none
