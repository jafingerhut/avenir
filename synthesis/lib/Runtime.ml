open Core

let action_data_of_string ?(sep = ';') (data_str : string) : Row.action_data
    =
  String.split data_str ~on:sep
  |> List.filter ~f:(fun s -> String.is_empty s |> not)
  |> List.map ~f:(fun arg_str ->
         let value_str, size_str =
           String.lsplit2 arg_str ~on:'#'
           |> Option.value ~default:(arg_str, "-1")
         in
         if String.is_substring value_str ~substring:"." then
           let addr_str =
             Option.(
               String.lsplit2 value_str ~on:'/'
               >>| fst |> value ~default:value_str)
           in
           Classbenching.parse_ip_mask "" (addr_str ^ "/32")
           |> Match.get_base_value
         else
           let value_str =
             if String.contains value_str ':' then
               String.substr_replace_all value_str ~pattern:":" ~with_:""
               |> Printf.sprintf "0x%s"
             else value_str
           in
           Value.big_make (Bigint.of_string value_str, int_of_string size_str))

let matches_of_string ?(sep = ';') (keys : (string * int) list)
    (data_str : string) : Match.t list =
  let data =
    String.split data_str ~on:sep |> List.filter ~f:(Fn.non String.is_empty)
  in
  if List.length data <> List.length keys then (
    Printf.printf "data is %s and keys are [%s]\n%!" data_str
      ( Util.fsts keys
      |> List.reduce ~f:(Printf.sprintf "%s,%s")
      |> Option.value ~default:"" ) ;
    failwith
    @@ Printf.sprintf "%d <> %d" (List.length data) (List.length keys) )
  else
    List.zip_exn keys data
    |> List.map ~f:(fun ((key, sz), match_str) ->
           match String.index match_str '[' with
           | Some _ -> (
             match String.lsplit2 match_str ~on:'#' with
             | Some (vals, sz) -> (
                 let size = int_of_string sz in
                 let range =
                   String.strip
                     ~drop:(fun c -> Char.(c = '[') || Char.(c = ']'))
                     vals
                 in
                 match String.lsplit2 range ~on:':' with
                 | Some (hi, lo) ->
                     Match.between_ key
                       (Value.big_make (Bigint.of_string hi, size))
                       (Value.big_make (Bigint.of_string lo, size))
                 | _ ->
                     Printf.sprintf
                       "Couldn't parse range match from string %s" range
                     |> failwith )
             | _ ->
                 failwith
                 @@ Printf.sprintf
                      "Couldn't parse range match from string %s, no # \
                       could be found"
                      match_str )
           | _ -> (
             match String.lsplit2 match_str ~on:'&' with
             | Some (fst, snd) -> (
               match String.lsplit2 snd ~on:'#' with
               | Some (prefix_str, size_str) ->
                   let size = int_of_string size_str in
                   let mask_hex_str =
                     if String.contains prefix_str ':' then
                       prefix_str
                       |> String.substr_replace_all ~pattern:":" ~with_:""
                       |> Printf.sprintf "0x%s"
                     else prefix_str
                   in
                   (* Printf.printf "COnverting %s\n to bigint\n%!"
                      mask_hex_str; *)
                   let mask = Bigint.of_string mask_hex_str in
                   let addr = Bigint.of_string fst in
                   Match.mask_ key
                     (Value.big_make (addr, size))
                     (Value.big_make (mask, size))
               | _ ->
                   Printf.sprintf
                     "Couldn't parse mask match from string %s, no #"
                     match_str
                   |> failwith )
             | _ ->
                 if String.is_substring match_str ~substring:"." then
                   if sz = 32 then
                     (*Parse IPv4*)
                     let match_str =
                       String.lsplit2 match_str ~on:'#'
                       |> Option.value_map ~f:fst ~default:match_str
                     in
                     Classbenching.parse_ip_mask key match_str
                   else
                     Printf.sprintf
                       "[Type error] cannot parse IPv4 address %s for key \
                        %s of length %d"
                       match_str key sz
                     |> failwith
                 else
                   (*assume its an integer??*)
                   let value_str, size_str =
                     String.lsplit2 match_str ~on:'#'
                     |> Option.value
                          ~default:(match_str, Printf.sprintf "%d" sz)
                   in
                   let size = int_of_string size_str in
                   let value = Bigint.of_string value_str in
                   Match.exact_ key (Value.big_make (value, size)) ))

let parse program filename : Edit.t list =
  let lines = In_channel.read_lines filename in
  let make_edit (data : string list) : Edit.t =
    match data with
    | ["ADD"; tbl_nm; matches; action_data; action] -> (
      match Cmd.get_schema_of_table tbl_nm program with
      | None -> failwith @@ Printf.sprintf "unrecognized table %s" tbl_nm
      | Some (keys, _, _) ->
          let keys = List.map keys ~f:Cmd.Key.to_sized in
          Add
            ( tbl_nm
            , ( matches_of_string keys matches
              , action_data_of_string action_data
              , int_of_string action ) ) )
    | ["DEL"; tbl_nm; action] -> Del (tbl_nm, int_of_string action)
    | _ ->
        Printf.sprintf "Unrecognized row (%d): %s\n%!" (List.length data)
          (List.intersperse data ~sep:"---" |> List.reduce_exn ~f:( ^ ))
        |> failwith
  in
  let edits =
    List.map lines ~f:(fun line -> String.split line ~on:',' |> make_edit)
  in
  edits

let parse_bmv2_entry cmd string : Edit.t =
  match String.split string ~on:' ' with
  | "table_add" :: tbl_name :: action_name :: cont ->
      let keys, actions, _ =
        Cmd.get_schema_of_table tbl_name cmd
        |> Option.value_exn
             ~message:(Printf.sprintf "Couldn't find table %s" tbl_name)
      in
      let keys = List.map keys ~f:Cmd.Key.to_sized in
      let action_id, (_, params, _) =
        List.findi actions ~f:(fun _ (name, _, _) ->
            String.(name = action_name))
        |> Option.value_exn
             ~message:
               (Printf.sprintf "Couldn't find action %s in %s" action_name
                  tbl_name)
      in
      let normalized_cont =
        String.concat ~sep:" " cont
        |> String.substr_replace_all ~pattern:"=>" ~with_:"$"
      in
      let matches, action_data =
        match String.lsplit2 normalized_cont ~on:'$' with
        | None -> (matches_of_string ~sep:' ' keys normalized_cont, [])
        | Some (matches_str, action_data_str) ->
            ( matches_of_string ~sep:' ' keys matches_str
            , action_data_of_string ~sep:' ' action_data_str
              |> List.fold2_exn params ~init:[] ~f:(fun acc (_, i) v ->
                     acc @ [Value.resize v i]) )
      in
      Add (tbl_name, (matches, action_data, action_id))
  | "table_delete" :: _ ->
      Printf.sprintf
        "[Unimplemented] We have not yet implemented table_deletes in \
         Avenir. Support for this feature is coming soon!"
      |> failwith
  | "table_set_default" :: _ ->
      Printf.sprintf
        "[Unsupported] Avenir does not support table_set_default"
      |> failwith
  | _ -> Printf.sprintf "unrecognized row %s" string |> failwith

let parse_bmv2 cmd filename : Edit.t list =
  In_channel.read_lines filename |> List.map ~f:(parse_bmv2_entry cmd)
