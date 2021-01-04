open Alcotest
open Avenir
open Ast
open Manip
open Equality

(*Testing weakest preconditions*)
let wp_skip_eq _ =
  let phi = (Var("x",8) %=% Var("y",8)) in
  Equality.same_test phi (wp `Negs Skip phi)

let wp_int_assign_eq _ =
  let pre = mkVInt(7,8) %=% Var ("g",8) in
  let cmd = "h" %<-% mkVInt(7,8) in
  let post = Var("h",8) %=% Var ("g",8) in
  same_test pre (wp `Negs cmd post)


let wp_var_assign_eq _ =
  let pre = Var("hgets",8) %=% Var ("g",8) in
  let cmd = "h" %<-% Var("hgets",8) in
  let post = Var("h",8) %=% Var ("g",8) in
  same_test pre (wp `Negs cmd post)


let wp_ordered_eq _ =
  let post = Var("g",8) %=% mkVInt(8,8) in
  let pre =
    bigand [
        bigand [
            Var ("h",8) %<>% mkVInt (2,8);
            mkNeg @@ bigor [Var("h",8) %=% mkVInt(99,8);
                            Var("h",8) %=% Var("g",8)] ;
          ] %=>% post;
        bigand [
            Var("h",8) %=%  mkVInt(99,8);
            Var("h",8) %<>% Var("g",8)
        ] %=>% post;
        Var("h",8) %=% Var ("g",9) %=>% (mkVInt(8,8) %=% mkVInt(8,8));
      ]
  in
  let cmd =
    mkOrdered [ Var ("h",8) %=%  Var ("g",8)    , "g" %<-% mkVInt (8,8);
                Var ("h",8) %=%  mkVInt (99,8)  , "h" %<-% mkVInt (4,8);
                Var ("h",8) %<>% mkVInt (2,8)   , "h" %<-% Var    ("g",8)
      ]
  in
  let post = Var("g",8) %=% mkVInt(8,8) in
  same_test pre (wp `Negs cmd post)

let wp_seq_eq _ =
  let open Manip in
  let cmd = ("h" %<-% mkVInt (10,8)) %:% ("h" %<-% mkVInt (80,8)) in
  let post = Var ("h",8) %=% Var ("g",8) in
  let pre = mkVInt (80,8) %=% Var ("g",8) in
  same_test pre (wp `Negs cmd post)


let wp_assume_eq _ = (* wp behaves well with assertions *)
  let open Manip in
  let phi = bigand [Var ("h",8) %<>% mkVInt (10,8); Var ("h",8) %<>% mkVInt (15,8)] in
  let cmd = Assume(phi) in
  let post =  Var ("h",8) %=% Var ("g",8) in
  same_test (phi %=>% post) (wp `Negs cmd post)


let test_wp : unit test_case list =
  [test_case "wp(skip,phi) = phi" `Quick wp_skip_eq;
   test_case "int assignment" `Quick wp_int_assign_eq;
   test_case "var assignment" `Quick wp_var_assign_eq;
   test_case "ordered" `Quick wp_ordered_eq;
   test_case "sequence" `Quick wp_seq_eq;
   test_case "assume" `Quick wp_assume_eq;
  ]
