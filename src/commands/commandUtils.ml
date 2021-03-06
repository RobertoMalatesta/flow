(**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

let print_version () =
  Utils.print_endlinef
    "Flow, a static type checker for JavaScript, version %s"
    FlowConfig.version

(* line split/transform utils *)
module Line : sig
  (* split string at nth line. if it exists, returns pre, line, post *)
  val split_nth : string -> int -> (string * string * string) option

  (* transform nth line, if it exists. returns reconstructed string *)
  val transform_nth : string -> int -> (string -> string) -> string

end = struct
  let breaks = "\r\n"

  let rec eol s x i =
    if i >= x then x else
    if String.contains breaks s.[i] then i else
    eol s x (i + 1)

  let rec line s x n i =
    if n <= 0 then i, eol s x (i + 1) else
    let i = eol s x i in
    if i >= x then x, x else
    line s x (n - 1) (i + 1)

  let split_nth s n =
    let x = String.length s in
    let i, j = line s x n 0 in
    if i = x then None else
    Some String.(sub s 0 i, sub s i (j - i), sub s j (x - j))

  let transform_nth s n f =
    match split_nth s n with
    | Some (pre, s, post) -> pre ^ (f s) ^ post
    | None -> s
end

let global_kill_time = ref None

let set_timeout max_wait_time_seconds =
  global_kill_time := Some (Sys.time() +. (float_of_int max_wait_time_seconds))

let timeout_go_boom () =
  print_endline "Timeout exceeded, exiting";
  exit 3

let check_timeout () =
  match !global_kill_time with
    | None -> ()
    | Some kill_time ->
        if Sys.time () > kill_time then timeout_go_boom ()

let sleep seconds =
  match !global_kill_time with
    | None -> Unix.sleep seconds
    | Some kill_time ->
        if int_of_float (ceil (kill_time -. Sys.time ())) <= seconds
        then timeout_go_boom ()
        else Unix.sleep seconds

let server_flags prev = CommandSpec.ArgSpec.(
  prev
  |> flag "--version" no_arg
      ~doc:"Print version number and exit"
  |> flag "--timeout" (optional int)
      ~doc:"Maximum time to wait, in seconds"
  |> flag "--from" (optional string)
      ~doc:"Specify client (for use by editor plugins)"
  |> flag "--show-all-errors" no_arg
      ~doc:"Print all errors (the default is to truncate after 50 errors)"
  |> flag "--retries" (optional int)
      ~doc:"Set the number of retries. (default: 3)"
  |> flag "--retry-if-init" (optional bool)
      ~doc:"retry if the server is initializing (default: true)"
  |> flag "--no-auto-start" no_arg
      ~doc:"If the server if it is not running, do not start it; just exit"
)

let json_flags prev = CommandSpec.ArgSpec.(
  prev
  |> flag "--json" no_arg ~doc:"Output results in JSON format"
)

type command_params = {
  version : bool ref;
  from : string ref;
  show_all_errors : bool ref;
  retries : int ref;
  retry_if_init : bool ref;
  timeout : int ref;
  no_auto_start : bool ref;
}

let collect_server_flags
    main
    version timeout from show_all_errors
    retries retry_if_init no_auto_start =
  let default def = function
  | Some x -> x
  | None -> def in
  main {
    version = ref version;
    from = ref (default "" from);
    show_all_errors = ref show_all_errors;
    retries = ref (default 3 retries);
    retry_if_init = ref (default true retry_if_init);
    timeout = ref (default 0 timeout);
    no_auto_start = ref no_auto_start;
  }

let start_flow_server root =
  Printf.fprintf stderr "Flow server launched for %s\n%!"
    (Path.to_string root);
  let flow_server = Printf.sprintf "%s start %s 1>&2"
    (Filename.quote (Sys.argv.(0)))
    (Filename.quote (Path.to_string root)) in
  match Unix.system flow_server with
    | Unix.WEXITED 0 -> ()
    | _ -> (Printf.fprintf stderr "Could not start flow server!\n"; exit 77)

let rec connect_helper autostart retries retry_if_init root =
  check_timeout ();
  try
    ClientUtils.connect root
  with
  | ClientExceptions.Server_initializing ->
      let init_msg = "flow server still initializing. If it was " ^
                     "just started this can take some time." in
      if retry_if_init
      then (
        Printf.fprintf stderr "%s Retrying... %s\r%!" init_msg (Tty.spinner());
        sleep 1;
        connect_helper autostart retries retry_if_init root
      ) else (
        Printf.fprintf stderr "%s Try again...\n%!" init_msg;
        exit 2
      )
  | ClientExceptions.Server_cant_connect ->
      retry autostart retries retry_if_init root
        1 "Error: could not connect to flow server, retrying..."
  | ClientExceptions.Server_busy ->
      retry autostart retries retry_if_init root
        1 "Error: flow server is busy, retrying..."
  | ClientExceptions.Server_out_of_date
  | ClientExceptions.Server_missing ->
    if autostart
    then (
      start_flow_server root;
      retry autostart retries retry_if_init root
        3 "The flow server will be ready in a moment."
    ) else (
      prerr_endline (Utils.spf
          "Error: There is no flow server running in '%s'."
          (Path.to_string root));
      exit 2
    )
  | _ -> Printf.fprintf stderr "Something went wrong :(\n%!"; exit 2

and retry autostart retries retry_if_init root delay message =
  check_timeout ();
  if retries > 0
  then (
    prerr_endline message;
    sleep delay;
    let retries = retries - 1 in
    connect_helper autostart retries retry_if_init root
  ) else (
    prerr_endline "Out of retries, exiting!";
    exit 2
  )

let connect_with_autostart command_values =
  connect_helper
    (not !(command_values.no_auto_start))
    !(command_values.retries)
    !(command_values.retry_if_init)

(* Given a valid file or directory, find a valid flow root directory *)
(* NOTE: exists on invalid file or .flowconfig not found! *)
let guess_root dir_or_file =
  let dir_or_file = match dir_or_file with
  | Some dir_or_file -> dir_or_file
  | None -> "." in
  if not (Sys.file_exists dir_or_file) then (
    Printf.fprintf stderr "Could not find file or directory %s; canceling \
    search for .flowconfig.\nSee \"flow init --help\" for more info\n%!" dir_or_file;
    exit 2
  ) else (
    let dir = if Sys.is_directory dir_or_file
      then dir_or_file
      else Filename.dirname dir_or_file in
    match ClientArgs.guess_root ".flowconfig" (Path.make dir) 50 with
    | Some root ->
        root
    | None ->
        Printf.fprintf stderr "Could not find a .flowconfig in %s or any \
        of its parent directories.\nSee \"flow init --help\" for more info\n%!" dir;
        exit 2
  )

(* convert 1,1 based line/column to 1,0 for internal use *)
let convert_input_pos (line, column) =
  let column =
    if column > 1
    then column - 1
    else 0 in
  (line, column)

(* copied (and adapted) from Hack's ClientCheck module *)
let get_path_of_file file =
  let path = Path.make file in
  if Path.file_exists path
  then Path.to_string path
  else
    (* Filename.concat does not return a normalized path when the file does
       not exist. Thus, we do it on our own... *)
    let file = Files_js.normalize_path (Sys.getcwd()) file in
    let path = Path.make file in
    Path.to_string path

let exe_name = Filename.basename Sys.executable_name
