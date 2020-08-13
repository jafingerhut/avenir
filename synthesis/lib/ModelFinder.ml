open Core
open Ast
open Manip
open Util
open Prover
open Tables

type opts =
  {injection : bool;
   hints : bool;
   paths : bool;
   only_holes: bool;
   mask : bool;
   restrict_mask : bool;
   nlp : bool;
   annot : bool;
   single : bool;
   domain : bool;
   no_defaults : bool;
   double : bool;
   reachable_adds : bool
  }

type t = {
    schedule : opts list;
    search_space : (test * Hint.t list) list;
  }

let condcat b app s =
  if b
  then Printf.sprintf "%s %s" s app
  else s

let string_of_opts (opts) : string =
  condcat opts.injection "injection" " "
  |> condcat opts.hints "hints"
  |> condcat opts.paths "paths"
  |> condcat opts.only_holes "only_holes"
  |> condcat opts.mask "mask"
  |> condcat opts.restrict_mask "restrict_mask"
  |> condcat opts.nlp "NLP"
  |> condcat opts.annot "annotations"
  |> condcat opts.single "single"
  |> condcat opts.domain "domain"
  |> condcat opts.no_defaults "no_defaults"
  |> condcat opts.double "double"
  |> condcat opts.reachable_adds "reachable_adds "

let no_opts =
  {injection = false;
   hints = false;
   paths = false;
   only_holes = false;
   mask = false;
   restrict_mask = false;
   nlp = false;
   annot = false;
   single = false;
   domain = false;
   no_defaults = false;
   double = false;
   reachable_adds = false;
  }


(* None > Mask > Paths > Injection > Hints > Only_Holes *)
let rec make_schedule opt =
  opt ::
    if opt.double then
      let opt' = {opt with double = false} in
      opt' :: make_schedule opt'
    else if opt.injection || opt.hints || opt.paths || opt.only_holes || opt.nlp || opt.domain then
      let opt' = {opt with injection=false;hints=false;paths=false;only_holes=false; nlp=false;domain = false} in
      opt' :: make_schedule opt'
    else if opt.no_defaults then
      let opt' = {opt with no_defaults = false} in
      opt' :: make_schedule opt'
    else []

let make_searcher (params : Parameters.t) (_ : ProfData.t ref) (_ : Problem.t) : t =
  let schedule = make_schedule {
                     injection = params.injection;
                     hints = params.hints;
                     paths = params.monotonic;
                     only_holes = params.only_holes;
                     mask = params.widening;
                     restrict_mask = params.restrict_mask;
                     annot = params.allow_annotations;
                     nlp = params.nlp;
                     single = params.unique_edits;
                     domain = params.domain;
                     no_defaults = params.no_defaults;
                     double = false;
                     reachable_adds = true;
                   } in
  {schedule; search_space = []}
  

let reindex_for_dels problem tbl i =
  Problem.phys_edits problem
  |>  List.fold ~init:(Some i)
        ~f:(fun cnt edit ->
          match cnt, edit with
          | Some n, Del (t,j) when t = tbl ->
             if i = j
             then None
             else Some (n-1)
          | _ -> cnt
        )

let compute_deletions (_ : value StringMap.t) (problem : Problem.t) =
  let phys_inst = Problem.phys_inst problem in
  StringMap.fold phys_inst ~init:[]
    ~f:(fun ~key:table_name ~data:rows dels ->
      dels @ List.filter_mapi rows ~f:(fun i _ ->
                 match reindex_for_dels problem table_name i with
                 | None -> None
                 | Some i' -> Some (table_name, i')
               )
    )

let hole_is_matched encode_tag tbl x sz (m : Match.t) =
  match encode_tag,m with
  | `Mask, Match.Mask (v,msk) ->
     let (h,hmsk) = Hole.match_holes_mask tbl x in
     (* Bitmask subsumption -- h&hm is subsumed by v &vm when (v & vm) & (h&hm) = (v & vm) *)
     let match_mask = mkMask (Value v) (Value msk) in
     match_mask
     %=% mkMask match_mask (mkMask (Hole(h,sz)) (Hole(hmsk,sz)))
  | `Exact, Match.Exact (v) ->
     let h = Hole.match_hole_exact tbl x in
     Hole(h,sz) %=% Value v
  | `Exact, Match.Mask (v,msk) ->
     let h = Hole.match_hole_exact tbl x in
     mkMask (Hole(h,sz)) (Value msk)
     %=% mkMask (Value v) (Value msk)
  | `Mask, Match.Exact (v) ->
     let (h,hmsk) = Hole.match_holes_mask tbl x in
     (Hole (h,sz) %=% Value v)
     %&% (Hole (hmsk,sz) %=% Value(Int(Bigint.(pow (of_int 2) (of_int sz) - one), sz)))
  | _, _ -> failwith "unexpected hole_is_match construction"


let well_formed_adds (params : Parameters.t) (problem : Problem.t) encode_tag =
  let phys_inst = Problem.phys_edited_instance params problem in
  let phys = Problem.phys problem in
  get_tables_vars phys ~keys_only:true
  |> List.fold
       ~init:True
       ~f:(fun accum (t,vs) ->
         let t_rows = Instance.get_rows phys_inst t in
         mkAnd accum @@
           (Hole.add_row_hole t %=% mkVInt(1,1)) %=>%
             List.fold t_rows ~init:True
               ~f:(fun acc (ms,_,_) ->
                 acc %&% !%(List.fold2_exn vs ms ~init:False
                              ~f:(fun acc (v,vsz) m ->
                                acc %+% hole_is_matched encode_tag t v vsz m
                              )
                           )
               )
       )

let adds_are_reachable params (problem : Problem.t) (opts : opts) encode_tag =
  if not opts.reachable_adds then True else
    let phys = Problem.phys problem in
    get_tables_vars phys ~keys_only:true
    |> List.fold
      ~init:True
      ~f:(fun acc (tbl_name,keys) ->
        let phys_inst = Problem.phys_inst problem in
        let phys_edits = Problem.phys_edits problem in
        let trunc =
          FastCX.truncated tbl_name phys
          |> Option.value_exn ~message:(Printf.sprintf "Couldn't find table %s" tbl_name)
          |> Instance.(apply params NoHoles `Exact (update_list params phys_inst phys_edits))
        in
        mkAnd acc @@
          mkImplies (Hole.add_row_hole tbl_name %=% mkVInt(1,1)) @@
            wp `Negs trunc @@
            Hint.default_match_holes tbl_name encode_tag keys
            %&% Instance.negate_rows phys_inst tbl_name keys
      )


let non_empty_adds (problem : Problem.t) =
  Problem.phys problem
  |> tables_of_cmd
  |> List.fold ~init:None
       ~f:(fun acc tbl ->
         match acc with
         | None -> Some (Hole.add_row_hole tbl %=% mkVInt(1,1))
         | Some acc -> Some (acc %+% (Hole.add_row_hole tbl %=% mkVInt(1,1)))
       )
  |> Option.value ~default:True

let single problem (opts : opts) query_holes =
  if not opts.single then True else
    List.fold query_holes ~init:True
      ~f:(fun acc (h,sz) ->
        mkAnd acc
          (if Hole.is_add_row_hole h
              && List.exists (Problem.phys_edits problem)
                   ~f:(fun e ->
                     Tables.Edit.table e = String.chop_prefix_exn h ~prefix:Hole.add_row_prefix
                   )
           then
             (Hole(h,sz) %=% mkVInt(0,sz))
           else
             acc))

let restrict_mask (opts : opts) query_holes =
  if not opts.restrict_mask then True else
    List.fold query_holes ~init:True
      ~f:(fun acc (h,sz) ->
        mkAnd acc @@
          if String.is_suffix h ~suffix:"_mask"
          then
            let h_value = String.chop_suffix_exn h ~suffix:"_mask" in
            let allfs = Printf.sprintf "0b%s" (String.make sz '1') |> Bigint.of_string in
            acc %&% ((Hole(h, sz) %=% Value(Int(allfs, sz)))
                     %+%  (Hole(h,sz) %=% mkVInt(0,sz)))
            %&% (Mask(Hole(h_value,sz), Hole(h,sz)) %=% Hole(h_value,sz))
          else True)

let active_domain_restrict params problem opts query_holes : test =
  if not opts.domain then True else
    let ints = (multi_ints_of_cmd (Problem.log_gcl_program params problem))
               @ (multi_ints_of_cmd (Problem.phys_gcl_program params problem))
               |> List.dedup_and_sort ~compare:(Stdlib.compare)
               |> List.filter ~f:(fun (v,_) -> Bigint.(v <> zero && v <> one)) in
    let test = List.fold query_holes ~init:True
      ~f:(fun acc (h,sz) ->
        let restr =
          List.fold ints
            ~init:(False)
            ~f:(fun acci (i,szi) ->
              mkOr acci @@
                if sz = szi
                   && not (String.is_suffix h ~suffix:"_mask")
                   && not (Hole.is_add_row_hole h)
                   && not (Hole.is_delete_hole h)
                   && not (Hole.is_which_act_hole h)
                then (Hole(h,sz) %=% Value(Int(i,szi))
                      %+% (Hole(h,sz) %=% mkVInt(0,szi))
                      %+% (Hole(h,sz) %=% mkVInt(1,szi)))
                else False)
        in
        if restr = False then acc else (acc %&% restr)
      )
    in
    (* let () = Printf.printf "\n\n\n\nactive domain restr \n %s\n\n\n\n%!" (string_of_test test) in *)
    test

let no_defaults (params : Parameters.t) opts fvs phys =
  if not opts.no_defaults then True else
    List.filter (holes_of_cmd phys)
      ~f:(fun (v,_) ->
        List.for_all fvs ~f:(fun (v',_) ->
                if List.exists [v'; Hole.add_row_prefix; Hole.delete_row_prefix; Hole.which_act_prefix]
                     ~f:(fun substring -> String.is_substring v ~substring)
                then (if params.debug then Printf.printf "%s \\in %s, so skipped\n%!" v v'; false)
                else (if params.debug then Printf.printf "%s \\not\\in %s, so kept\n%!" v v'; true)
          )
      )
    |> List.fold ~init:True ~f:(fun acc (v,sz) ->
           acc %&% (Hole(v,sz) %<>% mkVInt(0,sz)))




let apply_opts (params : Parameters.t) (data : ProfData.t ref) (problem : Problem.t) (opts : opts)  =
  let (in_pkt, out_pkt) = Problem.cexs problem |> List.hd_exn in
  (* |> refine_counter params problem in *)
  (* let () = Printf.printf "in : %s \n out: %s\n%!" (string_of_map in_pkt) (string_of_map out_pkt) in *)
  let st = Time.now () in
  let deletions = compute_deletions in_pkt problem in
  let hints = if opts.hints then
                let open Problem in
                Hint.construct (log problem) (phys problem) (log_edits problem |> List.hd_exn)
              else [] in
  let hole_protocol = if opts.only_holes
                      then Instance.OnlyHoles hints
                      else Instance.WithHoles (deletions, hints) in
  let hole_type =  if opts.mask then `Mask else `Exact in
  let phys = Problem.phys_gcl_holes {params with no_defaults = opts.no_defaults} problem hole_protocol hole_type  in
  if params.debug then Printf.printf "NEW Phys\n %s\n%!" (string_of_cmd phys);
  ProfData.update_time !data.model_holes_time st;
  let st = Time.now () in
  let fvs = List.(free_vars_of_cmd phys
                  |> filter ~f:(fun x -> exists (Problem.fvs problem) ~f:(Stdlib.(=) x))) in
  (* let fvs = problem.fvs in *)
  let in_pkt_form, out_pkt_form = Packet.to_test in_pkt ~fvs, Packet.to_test out_pkt ~fvs in
  let wp_list =
    if opts.paths then
      wp_paths `NoNegs phys out_pkt_form |> List.map ~f:(fun (c,t) -> c, in_pkt_form %=>% t)
    else
      let (sub, _(*passive_phys*), good_N, _) = good_execs fvs phys in
      let test =
        (if opts.double && List.length (Problem.cexs problem) > 1 then
           let (in_pkt', out_pkt') =  List.nth_exn (Problem.cexs problem) 1 in
           let in_pkt_form' = apply_init_test (Packet.to_test in_pkt' ~fvs) in
           let out_pkt_form' = apply_finals_sub_test (Packet.to_test out_pkt') sub in
           in_pkt_form' %=>% (good_N %=>% out_pkt_form')
         else
           True)
        %&% (apply_init_test in_pkt_form) %=>% (good_N %=>% apply_finals_sub_test out_pkt_form sub) in
      (* Printf.printf "--------------%s---------------\n%!" (string_of_test test); *)
      [phys, test ]
  in
  ProfData.update_time !data.search_wp_time st;
  let tests =
    List.filter_map wp_list
      ~f:(fun (cmd, spec) ->
        if spec = False || not (has_hole_test spec) then None else

          let () = if params.debug then
                     Printf.printf "Checking path with hole!\n  %s\n\n%!" (string_of_cmd cmd) in

          let wf_holes = List.fold (Problem.phys problem |> get_tables_actsizes) ~init:True
                           ~f:(fun acc (tbl,num_acts) ->
                             acc %&%
                               (Hole(Hole.which_act_hole_name tbl,max (log2 num_acts) 1)
                                %<=% mkVInt(num_acts-1,max (log2 num_acts) 1))) in
          let pre_condition =
            (Problem.model_space problem) %&% wf_holes %&% spec
            |> Injection.optimization {params with injection = opts.injection} problem
          in
          let query_test = wf_holes %&% pre_condition in
          let query_holes = holes_of_test query_test |> List.dedup_and_sort ~compare:(Stdlib.compare) in
          let out_test =
            query_test
            %&% adds_are_reachable params problem opts hole_type
            %&% no_defaults params opts fvs phys
            %&% single problem opts query_holes
            %&% active_domain_restrict params problem opts query_holes
            %&% restrict_mask opts query_holes
            %&% well_formed_adds params problem hole_type
            %&% non_empty_adds problem
          in
          Some (out_test, hints)) in
  tests

let holes_for_table table phys =
  match get_schema_of_table table phys with
  | None -> failwith @@ Printf.sprintf "couldn't find schema for %s\n%!" table
  | Some (ks, acts, _) ->
     List.bind ks ~f:(fun (k,_) ->
         let lo,hi = Hole.match_holes_range table k in
         let v,m = Hole.match_holes_mask table k in
         [Hole.match_hole_exact table k;lo;hi;v;m]
         |> List.dedup_and_sort ~compare:String.compare
       )
     @ List.(acts >>= fun (params,_) ->
             params >>| fst )

let holes_for_other_actions table phys actId =
  match get_schema_of_table table phys with
  | None -> failwith @@ Printf.sprintf"couldnt find schema for %s\n%!" table
  | Some (_, acts, _) ->
     List.foldi acts ~init:[]
       ~f:(fun i acc (params,_) ->
         acc @ if i = Bigint.to_int_exn actId then [] else List.map params ~f:fst
       )

let rec search (params : Parameters.t) data problem t : ((value StringMap.t * t) option)=
  match params.timeout with
  | Some (st,dur) when Time.(Span.(diff (now()) st > dur)) -> None
  | _ ->
     match t.search_space, t.schedule with
     | [], [] ->
        if params.debug then Printf.printf "Search failed\n%!";
        None
     | [], (opts::schedule) ->
        let () =
          Printf.printf "trying heuristics |%s|\n\n%!"
            (string_of_opts opts)
        in
        let search_space = apply_opts params data problem opts in
        (* Printf.printf "Searching with %d opts and %d paths\n%!" (List.length schedule) (List.length search_space); *)
        search params data problem {schedule; search_space}
     | (test,hints)::search_space, schedule ->
        (* Printf.printf "Check sat\n%!"; *)
        (* if params.debug then Printf.printf "MODELSPACE:\n%s\nTEST\n%s\n%!" (Problem.model_space problem |> string_of_test) (test |> string_of_test); *)
        let model_opt, dur = check_sat params (Problem.model_space problem %&% test) in
        ProfData.incr !data.model_z3_calls;
        ProfData.update_time_val !data.model_z3_time dur;
        (* Printf.printf "Sat Checked\n%!\n"; *)
        match model_opt with
        | Some model ->
           (* Printf.printf "Found a model, done \n%!"; *)
           let model = Hint.add_to_model (Problem.phys problem) hints model in
           if Problem.seen_attempt problem model then
             failwith @@
               Printf.sprintf "model has already been seen and its novel? %s"
                 (if Problem.model_space problem |> fixup_test model = True
                  then "yes! thats a contradiction"
                  else "no we're safe, so i guess we should keep searching?"
                 )
                 (* search params data problem {schedule; search_space} *)
           else begin
               if params.debug then
                 Printf.printf "IsNOVEL??? \n    %s \n"
                   (Problem.model_space problem
                    |> fixup_test model
                    |> string_of_test);
               Some (model,t)
             end
        (* end *)
        | _ ->
           (* Printf.printf "No model, keep searching with %d opts and %d paths \n%!" (List.length schedule) (List.length search_space); *)
           search params data problem {schedule; search_space}
