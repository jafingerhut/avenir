open Core
open Ast



let rec relabel (e : expr) (sz : size) : expr =
  let binop mk (e,e') = mk (relabel e sz) (relabel e' sz) in
  match e with
  | Value (Int(v, _)) -> Value(Int(v, sz))
  | Var (x, _) -> Var(x, sz)
  | Hole(h,_) -> Hole(h, sz)
  | Plus es | Times es | Minus es | Mask es | Xor es
    -> binop (ctor_for_binexpr e) es

let rec infer_expr (e : expr) : expr =
  let binop f (e1,e2) =
    let s1 = size_of_expr e1 in
    let s2 = size_of_expr e2 in
    assert (s1 >= -1);
    assert (s2 >= -1);
    if s1 = s2
    then if s1 = -1
         then f (infer_expr e1) (infer_expr e2)
         else e
    else
      if s1 = -1
      then f (relabel e1 s2) e2
      else
        if s2 = -1
        then f e1 (relabel e2 s1)
        else Printf.sprintf "sizes are known and differ!\n\t%s\t%s\n%!" (string_of_expr e1) (string_of_expr e2)
             |> failwith
  in
  match e with
  | Value _
    | Var _
    | Hole _ -> e
  | Plus es | Times es | Minus es | Mask es | Xor es
    -> binop (ctor_for_binexpr e) es

let rec infer_test (t : test) : test =
  match t with
  | True -> True
  | False -> False
  | Eq (e1,e2) -> infer_expr e1 %=% infer_expr e2
  | Le (e1,e2) -> infer_expr e1 %<=% infer_expr e2
  | And (b1,b2) -> infer_test b1 %&% infer_test b1
  | Or (b1,b2) -> infer_test b1 %+% infer_test b2
  | Impl (b1,b2) -> infer_test b1 %=>% infer_test b2
  | Iff (b1,b2) -> infer_test b1 %<=>% infer_test b2
  | Neg b -> !%(infer_test b)

let rec infer (p : cmd) : cmd =
  match p with
  | Skip -> Skip
  | Assign (s, e) -> s %<-% infer_expr e
  | Assume t -> Assume (infer_test t)
  | Assert t -> Assert (infer_test t)
  | Seq (c1,c2) -> infer c1 %:% infer c2
  | Select (typ, bs) ->
     mkSelect typ @@
       List.map bs ~f:(fun (t,c) -> infer_test t, infer c)
  | Apply {name; keys; actions; default} ->
     let actions' = List.map actions ~f:(infer_action) in
     mkApply (name, keys, actions', default)
  | While _ -> failwith "b t?"

and infer_action (params,c) = (params,infer c)
