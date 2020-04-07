open Core
open Ast
open Util

let rec expr_to_term expr : Smtlib.term =
  match expr with
  | Value (Int (num, _)) -> Smtlib.int_to_term (Bigint.to_int_exn num)
  | Var (v, _) -> String v
  | Hole (h, _) -> String h
  | Plus (e1, e2) -> Smtlib.add (expr_to_term e1) (expr_to_term e2)
  | Times (e1, e2) -> Smtlib.mul (expr_to_term e1) (expr_to_term e2)
  | Minus (e1, e2) -> Smtlib.sub (expr_to_term e1) (expr_to_term e2)

let rec test_to_term test : Smtlib.term =
  match test with
  | True -> Smtlib.bool_to_term true
  | False -> Smtlib.bool_to_term false
  | Eq (e1, e2) -> Smtlib.equals (expr_to_term e1) (expr_to_term e2)
  | Le (e1, e2) -> Smtlib.lte (expr_to_term e1) (expr_to_term e2)
  | And (t1, t2) -> Smtlib.and_ (test_to_term t1) (test_to_term t2)
  | Or (t1, t2) -> Smtlib.or_ (test_to_term t1) (test_to_term t2)
  | Impl (t1, t2) -> Smtlib.implies (test_to_term t1) (test_to_term t2)
  | Iff (t1, t2) -> Smtlib.and_
                      (Smtlib.implies (test_to_term t1) (test_to_term t2))
                      (Smtlib.implies (test_to_term t2) (test_to_term t1))
  | Neg t -> Smtlib.not_ (test_to_term t)

let rec term_to_exp term : Ast.expr =
  match

let rec term_to_test term : Ast.test =
  match term with
  | String s ->
  | Int i ->
  | BitVec (n, w) ->
  | BitVec64 i64 ->
  | Const id -> (match id with
      | Id "true" -> True
      | Id "false" -> False
    )
  | App (id, ts) -> (match ts with
  | [e1, e2] -> 
  |
  |)
  | Let (s, t1, t2) ->

    let toZ3String test = test_to_term test |> Smtlib.term_to_sexp |> Smtlib.sexp_to_string

let prover = Smtlib.make_solver "/usr/bin/z3"

let check (params : Parameters.t) typ (test : Ast.test) =
  let open Smtlib in
  let st = Time.now() in
  let response = match typ with
    |`Sat -> assert_ prover (test_to_term test); check_sat_using (UFBV : tactic) prover
    |`Valid -> assert_ prover (test_to_term (Neg test)); check_sat_using (QFBV : tactic) prover in
  let dur = Time.(diff (now()) st) in
  let model =
    if response = Sat then
      get_model prover
    else [] in (model, dur)
