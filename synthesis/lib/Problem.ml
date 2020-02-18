open Core
open Util
open Ast
open Tables

type t =
  {
    log : cmd;
    phys : cmd;
    log_inst : Instance.t;
    phys_inst : Instance.t;
    edits : Edit.t list;
    fvs : (string * int) list 
  }


let to_string (p : t) =
  Printf.sprintf "+-------------------------+\nLogical:\n%s\n\nPhysical:\n%s\nWRT:[%s]\n+-------------------------------+\n"
    (Instance.apply `NoHoles `Exact (Instance.update_list p.log_inst p.edits) p.log
     |> fst |> string_of_cmd)
    (Instance.apply `NoHoles `Exact p.phys_inst p.phys
     |> fst |> string_of_cmd)
    (List.map p.fvs ~f:(fun (x,sz) -> "(" ^ x ^ "#" ^ string_of_int sz ^ ")")
     |> List.reduce ~f:(fun x y -> x ^","^ y)
     |> Option.value ~default:"");
  
  
  

  