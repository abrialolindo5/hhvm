(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open SearchServiceRunner
open ServerEnv
open Reordered_argument_collections
module SLC = ServerLocalConfig

module CheckKind = struct
  type t =
    | Lazy
    | Full

  let to_string = function
    | Full -> "Full_check"
    | Lazy -> "Lazy_check"

  let is_full_check = function
    | Full -> true
    | Lazy -> false
end

module CheckStats = struct
  type t = {
    reparse_count: int;
    total_rechecked_count: int;
    time_first_result: seconds_since_epoch option;
  }

  (** Update field [time_first_result] if given timestamp is the
      first sent result. *)
  let record_result_sent_ts stats new_result_sent_ts =
    {
      stats with
      time_first_result =
        Option.first_some stats.time_first_result new_result_sent_ts;
    }
end

(*****************************************************************************)
(* Debugging *)
(*****************************************************************************)

let print_defs prefix defs =
  List.iter defs ~f:(fun (_, fname) -> Printf.printf "  %s %s\n" prefix fname)

let print_defs_per_file_pos defs_per_file_pos =
  SMap.iter defs_per_file_pos ~f:(fun x (funs, classes) ->
      Printf.printf "File: %s\n" x;
      print_defs "Fun" funs;
      print_defs "Class" classes);
  Printf.printf "\n";
  Out_channel.flush stdout;
  ()

let print_fast defs_per_file =
  SMap.iter defs_per_file ~f:(fun x (funs, classes) ->
      Printf.printf "File: %s\n" x;
      SSet.iter funs ~f:(Printf.printf "  Fun %s\n");
      SSet.iter classes ~f:(Printf.printf "  Class %s\n"));
  Printf.printf "\n";
  Out_channel.flush stdout;
  ()

(*****************************************************************************)
(* We want add all the declarations that were present in a file *before* the
 * current modification. The scenario:
 * File foo.php was defining the class A.
 * The user gets rid of class A (in foo.php)
 * In general, the type-checker determines what must be re-declared or
 * re-typechecked, by comparing the old and the new type-definitions.
 * That's why we are adding the 'old' definitions to the file.
 * In this case, the redecl phase (typing/typing_redecl_service.ml) is going
 * to compare the 'old' definition of A with the new one. It will realize that
 * the new one is missing, and go ahead and retype everything that depends
 * on A.
 * Without a call to add_old_decls, the class A wouldn't appear anywhere,
 * and we wouldn't realize that we have to re-check the types that depend
 * on A.
 *)
(*****************************************************************************)

let add_old_decls old_naming_table defs_per_file =
  Relative_path.Map.fold
    defs_per_file
    ~f:
      begin
        fun filename info_names acc ->
          match Naming_table.get_file_info old_naming_table filename with
          | None -> acc
          | Some old_info ->
            let old_info_names = FileInfo.simplify old_info in
            let info_names = FileInfo.merge_names old_info_names info_names in
            Relative_path.Map.add acc ~key:filename ~data:info_names
      end
    ~init:defs_per_file

(*****************************************************************************)
(* Removes the names that were defined in the files *)
(*****************************************************************************)

let remove_decls env defs_per_file_parsed =
  Relative_path.Map.iter defs_per_file_parsed ~f:(fun fn _ ->
      match Naming_table.get_file_info env.naming_table fn with
      | None -> ()
      | Some
          {
            FileInfo.funs;
            classes;
            typedefs;
            consts;
            modules;
            file_mode = _;
            comments = _;
            hash = _;
          } ->
        (* we use [snd] to strip away positions *)
        let snd (_, x, _) = x in
        Naming_global.remove_decls
          ~backend:(Provider_backend.get ())
          ~funs:(List.map funs ~f:snd)
          ~classes:(List.map classes ~f:snd)
          ~typedefs:(List.map typedefs ~f:snd)
          ~consts:(List.map consts ~f:snd)
          ~modules:(List.map modules ~f:snd))

(* If the only things that would change about file analysis are positions,
 * we're not going to recheck it, and positions in its error list might
 * become stale. Look if any of those positions refer to files that have
 * actually changed and add them to files to recheck. *)
let get_files_with_stale_errors
    ~(* Set of files that were reparsed (so their ASTs and positions
      * in them could have changed. *)
     reparsed
    ~(* A subset of files which errors we want to update, or None if we want
      * to update entire error list. *)
     filter
    ~(* Consider errors only coming from those phases *)
     phases
    ~(* Current global error list *)
     errors
    ~ctx =
  let fold =
    match filter with
    | None ->
      fun phase init f ->
        (* Looking at global files *)
        Errors.fold_errors errors ~phase ~init ~f:(fun source error acc ->
            f source error acc)
    | Some files ->
      fun phase init f ->
        (* Looking only at subset of files *)
        Relative_path.Set.fold files ~init ~f:(fun file acc ->
            Errors.fold_errors_in
              errors
              ~file
              ~phase
              ~init:acc
              ~f:(fun error acc -> f file error acc))
  in
  List.fold phases ~init:Relative_path.Set.empty ~f:(fun acc phase ->
      fold phase acc (fun source error acc ->
          if
            List.exists (User_error.to_list_ error) ~f:(fun e ->
                Relative_path.Set.mem
                  reparsed
                  (fst e |> Naming_provider.resolve_position ctx |> Pos.filename))
          then
            Relative_path.Set.add acc source
          else
            acc))

(*****************************************************************************)
(* Parses the set of modified files *)
(*****************************************************************************)

let push_errors env ~rechecked ~phase new_errors =
  let (diagnostic_pusher, time_errors_pushed) =
    Diagnostic_pusher.push_new_errors
      env.diagnostic_pusher
      ~rechecked
      new_errors
      ~phase
  in
  let env = { env with diagnostic_pusher } in
  (env, time_errors_pushed)

let erase_errors env = push_errors env Errors.empty

let push_and_accumulate_errors :
    env * Errors.t ->
    rechecked:Relative_path.Set.t ->
    Errors.t ->
    phase:Errors.phase ->
    env * Errors.t * seconds_since_epoch option =
 fun (env, errors_acc) ~rechecked new_errors ~phase ->
  let (env, time_errors_pushed) =
    push_errors env new_errors ~rechecked ~phase
  in
  let errors =
    Errors.incremental_update ~old:errors_acc ~new_:new_errors ~rechecked phase
  in
  (env, errors, time_errors_pushed)

(** Remove files which failed parsing from [defs_per_file] files and
    discard any previous errors they had in [omitted_phases] *)
let wont_do_failed_parsing
    defs_per_file ~stop_at_errors ~omitted_phases env failed_parsing =
  if stop_at_errors then
    let (env, time_first_erased) =
      List.fold
        omitted_phases
        ~init:(env, None)
        ~f:(fun (env, time_first_erased) phase ->
          let (env, time_erased) =
            erase_errors env ~rechecked:failed_parsing ~phase
          in
          let time_first_erased =
            Option.first_some time_first_erased time_erased
          in
          (env, time_first_erased))
    in
    let defs_per_file =
      Relative_path.Set.filter defs_per_file ~f:(fun k ->
          not
          @@ Relative_path.(
               Set.mem failed_parsing k && Set.mem env.editor_open_files k))
    in
    (env, defs_per_file, time_first_erased)
  else
    (env, defs_per_file, None)

let parsing genv env to_check cgroup_steps =
  let (ide_files, disk_files) =
    Relative_path.Set.partition
      (Relative_path.Set.mem env.editor_open_files)
      to_check
  in
  File_provider.remove_batch disk_files;
  Ast_provider.remove_batch disk_files;
  Fixme_provider.remove_batch disk_files;

  (* Do not remove ide files from file heap *)
  Ast_provider.remove_batch ide_files;
  Fixme_provider.remove_batch ide_files;

  let env =
    {
      env with
      local_symbol_table =
        SymbolIndexCore.remove_files
          ~sienv:env.local_symbol_table
          ~paths:to_check;
    }
  in
  SharedMem.GC.collect `gentle;
  let get_next =
    MultiWorker.next genv.workers (Relative_path.Set.elements disk_files)
  in
  let ctx = Provider_utils.ctx_from_server_env env in
  let (defs_per_file, errors, failed_parsing) =
    CgroupProfiler.step_start_end cgroup_steps "parsing" @@ fun _cgroup_step ->
    ( Direct_decl_service.go
        ctx
        genv.workers
        ~ide_files
        ~get_next
        ~trace:true
        ~cache_decls:
          (* Not caching here, otherwise oldification done in redo_type_decl will
             oldify the new version (and override the real old versions. *)
          false,
      Errors.empty,
      Relative_path.Set.empty )
  in

  SearchServiceRunner.update_fileinfo_map
    (Naming_table.create defs_per_file)
    ~source:SearchUtils.TypeChecker;

  (* During integration tests, we want to pretend that search is run
     synchronously *)
  let ctx = Provider_utils.ctx_from_server_env env in
  let env =
    {
      env with
      local_symbol_table =
        (let sie = env.local_symbol_table in
         if
           SearchServiceRunner.should_run_completely
             genv
             sie.SearchUtils.sie_provider
         then
           SearchServiceRunner.run_completely ctx sie
         else
           sie);
    }
  in

  (env, defs_per_file, errors, failed_parsing)

let get_interrupt_config genv env =
  MultiThreadedCall.{ handlers = env.interrupt_handlers genv; env }

(*****************************************************************************)
(* Where the action is! *)
(*****************************************************************************)

module type CheckKindType = sig
  (* Parsing treats files open in IDE and files coming from disk differently:
     *
     * - for IDE files, we need to look up their contents in the map in env,
     *     instead of reading from disk (duh)
     * - we parse IDE files in master process (to avoid passing env to the
     *     workers)
     * - to make the IDE more responsive, we try to shortcut the typechecking at
     *   the parsing level if there were parsing errors
  *)
  val get_files_to_parse : ServerEnv.env -> Relative_path.Set.t * bool

  (* files to parse, should we stop if there are parsing errors *)

  val get_defs_to_redecl :
    reparsed:Relative_path.Set.t ->
    env:ServerEnv.env ->
    ctx:Provider_context.t ->
    Relative_path.Set.t

  (* Which files to typecheck, based on results of declaration phase *)
  val get_defs_to_recheck :
    reparsed:Relative_path.Set.t ->
    defs_per_file:Naming_table.defs_per_file ->
    to_recheck:Relative_path.Set.t ->
    env:ServerEnv.env ->
    ctx:Provider_context.t ->
    enable_type_check_filter_files:bool ->
    Relative_path.Set.t * Relative_path.Set.t

  (* Update the global state based on resuts of parsing, naming and decl *)
  val get_env_after_decl :
    old_env:ServerEnv.env ->
    naming_table:Naming_table.t ->
    failed_naming:Relative_path.Set.t ->
    ServerEnv.env

  (* Update the global state based on resuts of typing *)
  val get_env_after_typing :
    old_env:ServerEnv.env ->
    errorl:Errors.t ->
    needs_recheck:Relative_path.Set.t ->
    ServerEnv.env

  val is_full : bool
end

module FullCheckKind : CheckKindType = struct
  let get_files_to_parse env =
    let files_to_parse =
      Relative_path.Set.(env.ide_needs_parsing |> union env.disk_needs_parsing)
    in
    (files_to_parse, false)

  let get_defs_to_redecl ~reparsed ~(env : env) ~ctx =
    (* Besides the files that actually changed, we want to also redeclare
     * those that have decl errors referring to files that were
     * reparsed, since positions in those errors can be now stale *)
    get_files_with_stale_errors
      ~reparsed
      ~filter:None
      ~phases:[Errors.Decl]
      ~errors:env.errorl
      ~ctx

  let get_defs_to_recheck
      ~reparsed
      ~defs_per_file
      ~to_recheck
      ~env
      ~ctx
      ~enable_type_check_filter_files =
    (* If the user has enabled a custom file filter, we want to only
     * type check files that pass the filter *)
    let to_recheck =
      if enable_type_check_filter_files then
        ServerCheckUtils.user_filter_type_check_files
          ~to_recheck
          ~reparsed
          ~is_ide_file:(Relative_path.Set.mem env.editor_open_files)
      else
        to_recheck
    in
    (* Besides the files that actually changed, we want to also recheck
     * those that have typing errors referring to files that were
     * reparsed, since positions in those errors can be now stale.
     *)
    let stale_errors =
      get_files_with_stale_errors
        ~reparsed
        ~filter:None
        ~phases:[Errors.Decl; Errors.Typing]
        ~errors:env.errorl
        ~ctx
    in
    let to_recheck = Relative_path.Set.union stale_errors to_recheck in
    let to_recheck = Relative_path.Set.union env.needs_recheck to_recheck in
    let to_recheck =
      Relative_path.Set.union
        (Relative_path.Set.of_list (Relative_path.Map.keys defs_per_file))
        to_recheck
    in
    (to_recheck, Relative_path.Set.empty)

  let get_env_after_decl ~old_env ~naming_table ~failed_naming =
    {
      old_env with
      naming_table;
      failed_naming;
      ide_needs_parsing = Relative_path.Set.empty;
      disk_needs_parsing = Relative_path.Set.empty;
    }

  let get_env_after_typing ~old_env ~errorl ~needs_recheck =
    let (full_check_status, remote) =
      if Relative_path.Set.is_empty needs_recheck then
        (Full_check_done, false)
      else
        (old_env.full_check_status, old_env.remote)
    in
    let why_needed_full_check =
      match old_env.init_env.why_needed_full_check with
      | Some why_needed_full_check
        when not (is_full_check_done full_check_status) ->
        Some why_needed_full_check
      | _ -> None
    in
    {
      old_env with
      errorl;
      needs_recheck;
      full_check_status;
      remote;
      init_env = { old_env.init_env with why_needed_full_check };
    }

  let is_full = true
end

module LazyCheckKind : CheckKindType = struct
  let get_files_to_parse env = (env.ide_needs_parsing, true)

  let some_ide_diagnosed_files env =
    Diagnostic_pusher.get_files_with_diagnostics env.diagnostic_pusher
    |> fun l -> List.take l 10 |> Relative_path.Set.of_list

  let is_ide_file env x =
    Relative_path.Set.mem (some_ide_diagnosed_files env) x
    || Relative_path.Set.mem env.editor_open_files x

  let get_defs_to_redecl ~reparsed ~env ~ctx =
    (* Same as FullCheckKind.get_defs_to_redecl, but we limit returned set only
     * to files that are relevant to IDE *)
    get_files_with_stale_errors
      ~reparsed
      ~filter:(Some (some_ide_diagnosed_files env))
      ~phases:[Errors.Decl]
      ~errors:env.errorl
      ~ctx

  let get_defs_to_recheck
      ~reparsed
      ~defs_per_file
      ~to_recheck
      ~env
      ~ctx
      ~enable_type_check_filter_files =
    (* If the user has enabled a custom file filter, we want to only
     * type check files that pass the filter. As such, we don't want
     * to add unwanted files to the "type check later"-queue *)
    let to_recheck =
      if enable_type_check_filter_files then
        ServerCheckUtils.user_filter_type_check_files
          ~to_recheck
          ~reparsed
          ~is_ide_file:(is_ide_file env)
      else
        to_recheck
    in
    (* Same as FullCheckKind.get_defs_to_recheck, but we limit returned set only
     * to files that are relevant to IDE *)
    let stale_errors =
      get_files_with_stale_errors
        ~ctx
        ~reparsed
        ~filter:(Some (some_ide_diagnosed_files env))
        ~phases:[Errors.Decl; Errors.Typing]
        ~errors:env.errorl
    in
    let to_recheck = Relative_path.Set.union to_recheck stale_errors in
    let (to_recheck_now, to_recheck_later) =
      Relative_path.Set.partition (is_ide_file env) to_recheck
    in
    let to_recheck_now =
      Relative_path.Set.union
        (Relative_path.Set.of_list (Relative_path.Map.keys defs_per_file))
        to_recheck_now
    in
    (to_recheck_now, to_recheck_later)

  let get_env_after_decl ~old_env ~naming_table ~failed_naming =
    {
      old_env with
      naming_table;
      failed_naming;
      ide_needs_parsing = Relative_path.Set.empty;
    }

  let get_env_after_typing ~old_env ~errorl ~needs_recheck =
    (* If it was started, it's still started, otherwise it needs starting *)
    let full_check_status =
      match old_env.full_check_status with
      | Full_check_started -> Full_check_started
      | _ -> Full_check_needed
    in
    {
      old_env with
      errorl;
      ide_needs_parsing = Relative_path.Set.empty;
      needs_recheck;
      full_check_status;
    }

  let is_full = false
end

module Make : functor (_ : CheckKindType) -> sig
  val type_check_core :
    ServerEnv.genv ->
    ServerEnv.env ->
    float ->
    check_reason:string ->
    CgroupProfiler.step_group ->
    ServerEnv.env * CheckStats.t * Telemetry.t
end =
functor
  (CheckKind : CheckKindType)
  ->
  struct
    let get_classes_from_old_and_new ~new_naming_table ~old_naming_table path =
      let new_classes =
        match Naming_table.get_file_info new_naming_table path with
        | None -> SSet.empty
        | Some info ->
          List.fold
            info.FileInfo.classes
            ~init:SSet.empty
            ~f:(fun acc (_, cid, _) -> SSet.add acc cid)
      in
      let old_classes =
        match Naming_table.get_file_info old_naming_table path with
        | None -> SSet.empty
        | Some info ->
          List.fold
            info.FileInfo.classes
            ~init:SSet.empty
            ~f:(fun acc (_, cid, _) -> SSet.add acc cid)
      in
      SSet.union new_classes old_classes

    let clear_failed_parsing env errors failed_parsing =
      (* In most cases, set of files processed in a phase is a superset
       * of files from previous phase - i.e if we run decl on file A, we'll also
       * run its typing.
       * In few cases we might choose not to run further stages for files that
       * failed parsing (see ~stop_at_errors). We need to manually clear out
       * error lists for those files. *)
      Relative_path.Set.fold
        failed_parsing
        ~init:(env, errors)
        ~f:(fun path acc ->
          let path = Relative_path.Set.singleton path in
          List.fold_left
            Errors.[Naming; Decl; Typing]
            ~init:acc
            ~f:(fun acc phase ->
              let (env, errors, _) =
                push_and_accumulate_errors
                  acc
                  ~rechecked:path
                  Errors.empty
                  ~phase
              in
              (env, errors)))

    type parsing_result = {
      parse_errors: Errors.t;
      failed_parsing: Relative_path.Set.t;
      defs_per_file_parsed: FileInfo.t Relative_path.Map.t;
      time_errors_pushed: seconds_since_epoch option;
    }

    let do_parsing
        (genv : genv)
        (env : env)
        ~(errors : Errors.t)
        ~(files_to_parse : Relative_path.Set.t)
        ~(cgroup_steps : CgroupProfiler.step_group) :
        ServerEnv.env * parsing_result =
      let (env, defs_per_file_parsed, errorl, failed_parsing) =
        parsing genv env files_to_parse cgroup_steps
      in
      let (env, errors, time_errors_pushed) =
        push_and_accumulate_errors
          (env, errors)
          errorl
          ~rechecked:files_to_parse
          ~phase:Errors.Parsing
      in
      let (env, errors) = clear_failed_parsing env errors failed_parsing in
      ( env,
        {
          parse_errors = errors;
          failed_parsing;
          defs_per_file_parsed;
          time_errors_pushed;
        } )

    type naming_result = {
      duplicate_name_errors: Errors.t;
      failed_naming: Relative_path.Set.t;
      naming_table: Naming_table.t;
      telemetry: Telemetry.t;
    }

    (** Update the naming_table, which is a map from filename to the names of
        toplevel symbols declared in that file: at any given point in time, we want
        to know what each file defines. The datastructure that maintains this information
        is called file_info. This code updates the file information.
        Also, update Typing_deps' table,
        which is a map from toplevel symbol hash (Dep.t) to filename.
        Also run Naming_global, updating the reverse naming table (which maps the names
        of toplevel symbols to the files in which they were declared) in shared
        memory. Does not run Naming itself (which converts an AST to a NAST by
        assigning unique identifiers to locals, among other things). The Naming
        module is something of a historical artifact and is slated for removal,
        but for now, it is run immediately before typechecking. *)
    let do_naming
        (env : env)
        (ctx : Provider_context.t)
        ~(defs_per_file_parsed : FileInfo.t Relative_path.Map.t)
        ~(cgroup_steps : CgroupProfiler.step_group) : naming_result =
      let telemetry = Telemetry.create () in
      let start_t = Unix.gettimeofday () in
      let count = Relative_path.Map.cardinal defs_per_file_parsed in
      CgroupProfiler.step_start_end cgroup_steps "naming" @@ fun _cgroup_step ->
      (* Update name->filename reverse naming table (global, mutable),
         and gather "duplicate name" errors *)
      remove_decls env defs_per_file_parsed;
      let (duplicate_name_errors, failed_naming) =
        Relative_path.Map.fold
          defs_per_file_parsed
          ~init:(Errors.empty, Relative_path.Set.empty)
          ~f:(fun file fileinfo (errorl, failed) ->
            let (errorl', failed') =
              Naming_global.ndecl_file_error_if_already_bound ctx file fileinfo
            in
            (Errors.merge errorl' errorl, Relative_path.Set.union failed' failed))
      in
      let t2 =
        Hh_logger.log_duration "Declare_names (name->filename)" start_t
      in
      (* Update filename->FileInfo.t forward naming table (into this local variable) *)
      let naming_table =
        Naming_table.update_many env.naming_table defs_per_file_parsed
      in
      (* final telemetry *)
      let t3 = Hh_logger.log_duration "Update_many (filename->names)" t2 in
      let heap_size = SharedMem.SMTelemetry.heap_size () in
      HackEventLogger.naming_end ~count start_t heap_size;
      let telemetry =
        telemetry
        |> Telemetry.float_ ~key:"update_reverse_duration" ~value:(t2 -. start_t)
        |> Telemetry.float_ ~key:"update_fwd_duration" ~value:(t3 -. t2)
        |> Telemetry.int_ ~key:"end_heap_mb" ~value:heap_size
        |> Telemetry.float_ ~key:"total_duration" ~value:(t3 -. start_t)
        |> Telemetry.int_ ~key:"count" ~value:count
        |> Telemetry.int_
             ~key:"failed_naming_count"
             ~value:(Relative_path.Set.cardinal failed_naming)
      in
      { duplicate_name_errors; failed_naming; naming_table; telemetry }

    type redecl_result = {
      changed: Typing_deps.DepSet.t;
      to_recheck: Relative_path.Set.t;
      to_recheck_deps: Typing_deps.DepSet.t;
      old_decl_missing_count: int;
    }

    let do_redecl
        (genv : genv)
        (env : env)
        ~(defs_per_file : FileInfo.names Relative_path.Map.t)
        ~(naming_table : Naming_table.t)
        ~(cgroup_steps : CgroupProfiler.step_group) : redecl_result =
      let get_classes =
        get_classes_from_old_and_new
          ~new_naming_table:naming_table
          ~old_naming_table:env.naming_table
      in
      let bucket_size = genv.local_config.SLC.type_decl_bucket_size in
      let ctx = Provider_utils.ctx_from_server_env env in
      let {
        Decl_redecl_service.errors = _;
        fanout = { Decl_redecl_service.changed; to_recheck = to_recheck_deps };
        old_decl_missing_count;
      } =
        CgroupProfiler.step_start_end cgroup_steps "redecl"
        @@ fun _cgroup_step ->
        Decl_redecl_service.redo_type_decl
          ~bucket_size
          ctx
          ~during_init:false
          genv.workers
          get_classes
          ~previously_oldified_defs:FileInfo.empty_names
          ~defs:defs_per_file
      in
      ServerProgress.write "determining files";
      let to_recheck = Naming_provider.get_files ctx to_recheck_deps in
      { changed; to_recheck; to_recheck_deps; old_decl_missing_count }

    type type_checking_result = {
      env: ServerEnv.env;
      errors: Errors.t;
      telemetry: Telemetry.t;
      files_checked: Relative_path.Set.t;
      full_check_done: bool;
      needs_recheck: Relative_path.Set.t;
      total_rechecked_count: int;
      time_first_typing_error: seconds option;
    }

    let do_type_checking
        (genv : genv)
        (env : env)
        (capture_snapshot : ServerRecheckCapture.snapshot)
        ~(errors : Errors.t)
        ~(files_to_check : Relative_path.Set.t)
        ~(files_to_parse : Relative_path.Set.t)
        ~(lazy_check_later : Relative_path.Set.t)
        ~(check_reason : string)
        ~(cgroup_steps : CgroupProfiler.step_group) : type_checking_result =
      let telemetry = Telemetry.create () in
      if Relative_path.(Set.mem files_to_check default) then
        Hh_logger.log "WARNING: rechecking definition in a dummy file";
      let interrupt = get_interrupt_config genv env in
      let memory_cap =
        genv.local_config.ServerLocalConfig.max_typechecker_worker_memory_mb
      in
      let longlived_workers =
        genv.local_config.ServerLocalConfig.longlived_workers
      in
      let cgroup_typecheck_telemetry = ref None in
      let (errorl', telemetry, env, cancelled, time_first_typing_error) =
        let ctx = Provider_utils.ctx_from_server_env env in
        CgroupProfiler.step_start_end
          cgroup_steps
          ~telemetry_ref:cgroup_typecheck_telemetry
          "type check"
        @@ fun () ->
        let ( ( env,
                {
                  Typing_check_service.errors = errorl;
                  delegate_state;
                  telemetry;
                  diagnostic_pusher =
                    (diagnostic_pusher, time_first_typing_error);
                } ),
              cancelled ) =
          Typing_check_service.go_with_interrupt
            ~diagnostic_pusher:env.ServerEnv.diagnostic_pusher
            ctx
            genv.workers
            env.typing_service.delegate_state
            telemetry
            (files_to_check |> Relative_path.Set.elements)
            ~interrupt
            ~memory_cap
            ~longlived_workers
            ~check_info:
              (ServerCheckUtils.get_check_info
                 ~check_reason
                 ~log_errors:CheckKind.is_full
                 genv
                 env)
        in
        let env =
          {
            env with
            diagnostic_pusher =
              Option.value diagnostic_pusher ~default:env.diagnostic_pusher;
            typing_service = { env.typing_service with delegate_state };
          }
        in
        (errorl, telemetry, env, cancelled, time_first_typing_error)
      in
      let telemetry =
        telemetry
        |> Telemetry.object_opt ~key:"cgroup" ~value:!cgroup_typecheck_telemetry
        |> Telemetry.object_ ~key:"gc" ~value:(Telemetry.quick_gc_stat ())
        |> Telemetry.object_
             ~key:"proc"
             ~value:(ProcFS.telemetry_for_pid (Unix.getpid ()))
      in

      let files_checked = files_to_check in
      (* Add new things that need to be rechecked *)
      let needs_recheck =
        Relative_path.Set.union env.needs_recheck lazy_check_later
      in
      (* Remove things that were cancelled from things we started rechecking... *)
      let (files_checked, needs_recheck) =
        List.fold
          cancelled
          ~init:(files_checked, needs_recheck)
          ~f:(fun (files_checked, needs_recheck) path ->
            ( Relative_path.Set.remove files_checked path,
              Relative_path.Set.add needs_recheck path ))
      in
      (* ... leaving only things that we actually checked, and which can be
       * removed from needs_recheck *)
      let needs_recheck = Relative_path.Set.diff needs_recheck files_checked in
      let errors =
        Errors.(
          incremental_update
            ~old:errors
            ~new_:errorl'
            ~rechecked:files_checked
            Typing)
      in
      let (env, _future) : ServerEnv.env * string Future.t option =
        ServerRecheckCapture.update_after_recheck
          genv
          env
          capture_snapshot
          ~changed_files:files_to_parse
          ~cancelled_files:(Relative_path.Set.of_list cancelled)
          ~rechecked_files:files_checked
          ~recheck_errors:errorl'
          ~all_errors:errors
      in
      let full_check_done =
        CheckKind.is_full && Relative_path.Set.is_empty needs_recheck
      in

      let total_rechecked_count = Relative_path.Set.cardinal files_checked in
      {
        env;
        errors;
        telemetry;
        files_checked;
        full_check_done;
        needs_recheck;
        total_rechecked_count;
        time_first_typing_error;
      }

    let quantile ~index ~count : Relative_path.Set.t -> Relative_path.Set.t =
     fun files ->
      let file_count_in_quantile = Relative_path.Set.cardinal files / count in
      let (file_count_in_quantile, index) =
        if Int.equal 0 file_count_in_quantile then
          let count = Relative_path.Set.cardinal files in
          let file_count_in_quantile = 1 in
          let index =
            if index >= count then
              count - 1
            else
              index
          in
          (file_count_in_quantile, index)
        else
          (file_count_in_quantile, index)
      in
      (* Work with BigList-s the same way Typing_check_service does, to preserve
         the same typechecking order within the quantile. *)
      let files = files |> Relative_path.Set.elements |> BigList.create in
      let rec pop_quantiles n files =
        let (bucket, files) = BigList.split_n files file_count_in_quantile in
        if n <= 0 then
          bucket
        else
          pop_quantiles (n - 1) files
      in
      pop_quantiles index files |> Relative_path.Set.of_list

    let type_check_core genv env start_time ~check_reason cgroup_steps =
      let t = Unix.gettimeofday () in
      (* `start_time` is when the recheck_loop started and includes preliminaries like
       * reading about file-change notifications and communicating with client.
       * We record all our telemetry uniformally with respect to this start.
       * `t` is legacy, used for ad-hoc duration reporting within this function.
       * For the following, env.int_env.why_needed_full_check is set to Some by
       * ServerLazyInit, and we include it here, and then it's subsequently
       * set to None at the end of this method by the call to [get_env_after_typing].
       * Thus, if it's present here, it means the typecheck we're about to do is
       * the initial one of a lazy init. *)
      let telemetry =
        Telemetry.create ()
        |> Telemetry.object_opt
             ~key:"init"
             ~value:
               (Option.map
                  env.ServerEnv.init_env.ServerEnv.why_needed_full_check
                  ~f:ServerEnv.Init_telemetry.get)
      in
      let time_first_error = None in
      let env =
        if CheckKind.is_full then
          { env with full_check_status = Full_check_started }
        else
          env
      in
      let (files_to_parse, stop_at_errors) = CheckKind.get_files_to_parse env in
      (* We need to do naming phase for files that failed naming in a previous cycle.
       * "Failed_naming" comes from duplicate name errors; the idea is that a change
       * deletes one of the duplicates, well, this change should cause us to re-parse
       * and re-process the remaining duplicate so it can be properly recorded in the
       * forward and reverse naming tables (even though the remaining duplicate
       * didn't itself change). *)
      if not (Relative_path.Set.is_empty env.failed_naming) then
        Hh_logger.log
          "Also reparsing these files with failed naming: %s"
          (Relative_path.Set.elements env.failed_naming
          |> List.map ~f:Relative_path.suffix
          |> String.concat ~sep:" ");
      let files_to_parse =
        Relative_path.Set.union files_to_parse env.failed_naming
      in

      let reparse_count = Relative_path.Set.cardinal files_to_parse in
      if reparse_count = 1 then
        files_to_parse
        |> Relative_path.Set.choose
        |> Relative_path.to_absolute
        |> Hh_logger.log "Processing changes to 1 file: %s"
      else
        Hh_logger.log "Processing changes to %d files" reparse_count;

      let telemetry =
        if CheckKind.is_full then (
          let check_count = Relative_path.Set.cardinal env.needs_recheck in
          Hh_logger.log
            "Processing deferred typechecking for %d file(s)"
            check_count;
          telemetry |> Telemetry.int_ ~key:"check_count" ~value:check_count
        ) else
          telemetry
      in

      (* PARSING ***************************************************************)
      ServerProgress.write
        ~include_in_logs:false
        "parsing %d files"
        reparse_count;
      let logstring = Printf.sprintf "Parsing %d files" reparse_count in
      Hh_logger.log "Begin %s" logstring;

      (* Parse all changed files. This clears the file contents cache prior
          to parsing. *)
      let parse_t = Unix.gettimeofday () in
      let telemetry =
        Telemetry.duration telemetry ~key:"parse_start" ~start_time
      in
      let errors = env.errorl in
      let ( env,
            {
              parse_errors = errors;
              failed_parsing;
              defs_per_file_parsed;
              time_errors_pushed;
            } ) =
        do_parsing genv env ~errors ~files_to_parse ~cgroup_steps
      in
      let time_first_error =
        Option.first_some time_first_error time_errors_pushed
      in

      let hs = SharedMem.SMTelemetry.heap_size () in
      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"parse_end" ~start_time
        |> Telemetry.int_ ~key:"parse_end_heap_size" ~value:hs
        |> Telemetry.int_ ~key:"parse_count" ~value:reparse_count
      in
      HackEventLogger.parsing_end_for_typecheck t hs ~parsed_count:reparse_count;
      let t = Hh_logger.log_duration logstring t in

      (* UPDATE NAMING TABLES **************************************************)
      ServerProgress.write ~include_in_logs:false "updating naming tables";
      let logstring = "updating naming tables" in
      Hh_logger.log "Begin %s" logstring;
      let telemetry =
        Telemetry.duration telemetry ~key:"naming_start" ~start_time
      in
      let ctx = Provider_utils.ctx_from_server_env env in
      let {
        duplicate_name_errors;
        failed_naming;
        naming_table;
        telemetry = naming_telemetry;
      } =
        do_naming env ctx ~defs_per_file_parsed ~cgroup_steps
        (* Note: although do_naming updates global reverse-naming-table maps,
           the updated forward-naming-table "naming_table" only gets assigned
           into env.naming_table later on, in get_env_after_decl. *)
      in
      let t = Hh_logger.log_duration logstring t in
      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"naming_end" ~start_time
        |> Telemetry.object_ ~key:"naming" ~value:naming_telemetry
      in

      let (env, errors, time_errors_pushed) =
        push_and_accumulate_errors
          (env, errors)
          duplicate_name_errors
          ~rechecked:
            (defs_per_file_parsed
            |> Relative_path.Map.keys
            |> Relative_path.Set.of_list)
          ~phase:Errors.Naming
      in
      let time_first_error =
        Option.first_some time_first_error time_errors_pushed
      in

      (* REDECL PHASE 1 ********************************************************)
      ServerProgress.write "determining changes";
      let deptable_unlocked =
        Typing_deps.allow_dependency_table_reads env.deps_mode true
      in

      Hh_logger.log "(Recomputing type declarations in relation to naming)";
      (* failed_naming can be a superset of keys in defs_per_file - see comment in Naming_global.ndecl_file *)
      let failed_decl =
        CheckKind.get_defs_to_redecl ~reparsed:files_to_parse ~env ~ctx
      in
      (* The term [defs_per_file] doesn't mean anything. It's just exactly the same as defs_per_file_parsed,
         that is a filename->FileInfo.t map of the files we just parsed,
         except it's just filename->FileInfo.names -- i.e. purely the names, without positions. *)
      let defs_per_file =
        Naming_table.to_defs_per_file (Naming_table.create defs_per_file_parsed)
      in
      let defs_per_file =
        ServerCheckUtils.extend_defs_per_file
          genv
          defs_per_file
          naming_table
          failed_naming
      in
      let defs_per_file =
        ServerCheckUtils.extend_defs_per_file
          genv
          defs_per_file
          naming_table
          failed_decl
      in
      let defs_per_file = add_old_decls env.naming_table defs_per_file in

      let count = Relative_path.Map.cardinal defs_per_file in
      let logstring = Printf.sprintf "Type declaration for %d files" count in
      Hh_logger.log "Begin %s" logstring;
      Hh_logger.log
        "(Recomputing type declarations in changed files and determining immediate typechecking fanout)";
      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"redecl_start" ~start_time
        |> Telemetry.int_ ~key:"redecl_file_count" ~value:count
      in

      (* Compute fanout. Here we compare the old and new versions of
         the declarations defined in all changed files, and collect the set of
         files which need to be re-typechecked as a consequence of those changes. *)
      let { changed; to_recheck; to_recheck_deps; old_decl_missing_count } =
        do_redecl genv env ~defs_per_file ~naming_table ~cgroup_steps
      in
      let telemetry =
        telemetry
        |> Telemetry.int_
             ~key:"old_decl_missing_count"
             ~value:old_decl_missing_count
      in

      let hs = SharedMem.SMTelemetry.heap_size () in
      HackEventLogger.first_redecl_end t hs;
      let t = Hh_logger.log_duration logstring t in
      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"redecl_end" ~start_time
        |> Telemetry.int_ ~key:"redecl_end_heap_size" ~value:hs
      in

      let telemetry =
        Telemetry.duration
          telemetry
          ~key:"revtrack_decl_changed_end"
          ~start_time
      in

      ServerRevisionTracker.typing_changed
        genv.local_config
        (Relative_path.Set.cardinal to_recheck);

      (* we use lazy here to avoid expensive string generation when logging
       * is not enabled *)
      Hh_logger.log_lazy ~category:"fanout_information"
      @@ lazy
           Hh_json.(
             json_to_string
             @@ JSON_Object
                  [
                    ("tag", string_ "incremental_fanout");
                    ( "hashes",
                      array_
                        string_
                        Typing_deps.(
                          List.map ~f:Dep.to_hex_string
                          @@ DepSet.elements to_recheck_deps) );
                    ( "files",
                      array_
                        string_
                        Relative_path.(
                          List.map ~f:suffix @@ Set.elements to_recheck) );
                  ]);

      let env =
        CheckKind.get_env_after_decl ~old_env:env ~naming_table ~failed_naming
      in
      (* HANDLE PRECHECKED FILES AFTER LOCAL CHANGES ***************************)
      ServerProgress.write "determining trunk changes";
      Hh_logger.log "Begin evaluating prechecked changes";
      let telemetry =
        Telemetry.duration telemetry ~key:"prechecked1_start" ~start_time
      in

      let (env, prechecked1_telemetry) =
        ServerPrecheckedFiles.update_after_local_changes
          genv
          env
          changed
          ~start_time
      in

      let t = Hh_logger.log_duration "Evaluating prechecked changes" t in
      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"prechecked1_end" ~start_time
        |> Telemetry.object_ ~key:"prechecked1" ~value:prechecked1_telemetry
        |> Telemetry.int_
             ~key:"prechecked1_changed"
             ~value:(Typing_deps.DepSet.cardinal changed)
      in

      let (_ : bool) =
        Typing_deps.allow_dependency_table_reads env.deps_mode deptable_unlocked
      in

      (* Checking this before starting typechecking because we want to attribtue
       * big rechecks to rebases, even when restarting is disabled *)
      if
        genv.local_config.ServerLocalConfig.hg_aware_recheck_restart_threshold
        = 0
      then
        ServerRevisionTracker.check_blocking ();
      let telemetry =
        Telemetry.duration
          telemetry
          ~key:"revtrack3_check_blocking_end"
          ~start_time
      in

      (* TYPE CHECKING *********************************************************)
      let type_check_start_t = Unix.gettimeofday () in
      ServerProgress.write "typechecking";

      (* For a full check, typecheck everything which may be affected by the
         changes. For a lazy check, typecheck only the affected files which are
         open in the IDE, leaving other affected files to be lazily checked later.
         In either case, don't attempt to typecheck files with parse errors. *)
      let (files_to_check, lazy_check_later) =
        CheckKind.get_defs_to_recheck
          ~reparsed:files_to_parse
          ~defs_per_file
          ~to_recheck
          ~env
          ~ctx
          ~enable_type_check_filter_files:
            genv.ServerEnv.local_config
              .ServerLocalConfig.enable_type_check_filter_files
      in
      let env =
        ServerRemoteUtils.start_delegate_if_needed
          env
          genv
          (Relative_path.Set.cardinal files_to_check)
          errors
      in
      let (env, files_to_check, time_erased_errors) =
        wont_do_failed_parsing
          files_to_check
          ~stop_at_errors
          ~omitted_phases:[Errors.Typing]
          env
          failed_parsing
      in
      let time_first_error =
        Option.first_some time_first_error time_erased_errors
      in

      ServerProgress.write
        "typechecking %d files"
        (Relative_path.Set.cardinal files_to_check);

      let files_to_check =
        match genv.local_config.ServerLocalConfig.workload_quantile with
        | None -> files_to_check
        | Some { ServerLocalConfig.index; count } ->
          let files_to_check = quantile ~index ~count files_to_check in
          Hh_logger.log
            "Will typecheck %d-th %d-quantile only, containing %d files."
            index
            count
            (Relative_path.Set.cardinal files_to_check);
          files_to_check
      in

      let to_recheck_count = Relative_path.Set.cardinal files_to_check in
      (* The intent of capturing the snapshot here is to increase the likelihood
          of the state-on-disk being the same as what the parser saw *)
      let (env, capture_snapshot) =
        ServerRecheckCapture.update_before_recheck
          genv
          env
          ~to_recheck_count
          ~changed_files:files_to_parse
          ~parse_t
      in
      Hh_logger.log "Begin typechecking %d files." to_recheck_count;

      ServerCheckpoint.process_updates files_to_check;

      let telemetry =
        Telemetry.duration telemetry ~key:"typecheck_start" ~start_time
      in
      (* Typecheck all of the files we determined might need rechecking as a
         consequence of the changes (or, in a lazy check,
         the subset of those
         files which are open in an IDE buffer). *)
      let {
        env;
        errors;
        telemetry = typecheck_telemetry;
        files_checked;
        full_check_done = _;
        needs_recheck;
        total_rechecked_count;
        time_first_typing_error;
      } =
        do_type_checking
          genv
          env
          capture_snapshot
          ~errors
          ~files_to_check
          ~files_to_parse
          ~lazy_check_later
          ~check_reason
          ~cgroup_steps
      in
      let time_first_error =
        Option.first_some time_first_error time_first_typing_error
      in

      let heap_size = SharedMem.SMTelemetry.heap_size () in

      ServerProgress.write "typecheck ending";
      let logstring =
        Printf.sprintf
          "Typechecked %d files [%d errors]"
          total_rechecked_count
          (Errors.count errors)
      in
      let t = Hh_logger.log_duration logstring t in
      Hh_logger.log "Total: %f\n%!" (t -. start_time);

      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"typecheck_end" ~start_time
        |> Telemetry.object_ ~key:"typecheck" ~value:typecheck_telemetry
        |> Telemetry.object_
             ~key:"hash"
             ~value:(ServerUtils.log_and_get_sharedmem_load_telemetry ())
        |> Telemetry.int_opt
             ~key:"depgraph_delta_num_edges"
             ~value:
               (Typing_deps.Telemetry.depgraph_delta_num_edges
                  (Provider_context.get_deps_mode ctx))
        |> Telemetry.int_ ~key:"typecheck_heap_size" ~value:heap_size
        |> Telemetry.int_
             ~key:"typecheck_to_recheck_count"
             ~value:to_recheck_count
        |> Telemetry.int_
             ~key:"typecheck_total_rechecked_count"
             ~value:total_rechecked_count
        |> Telemetry.int_
             ~key:"typecheck_files_checked"
             ~value:(Relative_path.Set.cardinal files_checked)
        |> Telemetry.int_
             ~key:"typecheck_lazy_check_later_count"
             ~value:(Relative_path.Set.cardinal lazy_check_later)
        |> Telemetry.int_opt
             ~key:"typecheck_mem_cap"
             ~value:
               genv.local_config
                 .ServerLocalConfig.max_typechecker_worker_memory_mb
        |> Telemetry.int_opt
             ~key:"typecheck_defer_decl_threshold"
             ~value:
               genv.local_config
                 .ServerLocalConfig.defer_class_declaration_threshold
        |> Telemetry.bool_
             ~key:"use_max_typechecker_worker_memory_for_decl_deferral"
             ~value:
               genv.local_config
                 .ServerLocalConfig
                  .use_max_typechecker_worker_memory_for_decl_deferral
        |> Telemetry.bool_
             ~key:"enable_type_check_filter_files"
             ~value:
               genv.local_config
                 .ServerLocalConfig.enable_type_check_filter_files
        |> Telemetry.bool_
             ~key:"typecheck_longlived_workers"
             ~value:genv.local_config.ServerLocalConfig.longlived_workers
      in

      (* INVALIDATE FILES (EXPERIMENTAL TYPES IN CODEGEN) **********************)
      ServerInvalidateUnits.go
        genv
        ctx
        files_checked
        defs_per_file_parsed
        naming_table;

      let telemetry =
        Telemetry.duration telemetry ~key:"invalidate_end" ~start_time
      in

      (* WRAP-UP ***************************************************************)
      let needs_recheck =
        if Option.is_some genv.local_config.ServerLocalConfig.workload_quantile
        then
          (* If we were typechecking quantiles only, then artificially assume that everything
             was typechecked. Otherwise the next recheck iteration will keep typechecking the other
             quantiles. *)
          Relative_path.Set.empty
        else
          needs_recheck
      in
      let env =
        CheckKind.get_env_after_typing
          ~old_env:env
          ~errorl:errors
          ~needs_recheck
      in

      (* STATS LOGGING *********************************************************)
      if SharedMem.SMTelemetry.hh_log_level () > 0 then begin
        Measure.print_stats ();
        Measure.print_distributions ()
      end;
      let telemetry =
        if SharedMem.SMTelemetry.hh_log_level () > 0 then
          Telemetry.object_
            telemetry
            ~key:"shmem"
            ~value:(SharedMem.SMTelemetry.get_telemetry ())
        else
          telemetry
      in

      let telemetry =
        telemetry
        |> Telemetry.object_
             ~key:"errors"
             ~value:(Errors.as_telemetry env.errorl)
        |> Telemetry.object_
             ~key:"repo_states"
             ~value:(Watchman.RepoStates.get_as_telemetry ())
      in

      (* HANDLE PRECHECKED FILES AFTER RECHECK *********************************)
      let telemetry =
        Telemetry.duration telemetry ~key:"prechecked2_start" ~start_time
      in
      let deptable_unlocked =
        Typing_deps.allow_dependency_table_reads env.deps_mode true
      in
      let (env, prechecked2_telemetry) =
        ServerPrecheckedFiles.update_after_recheck
          genv
          env
          files_checked
          ~start_time
      in
      let (_ : bool) =
        Typing_deps.allow_dependency_table_reads env.deps_mode deptable_unlocked
      in
      let telemetry =
        telemetry
        |> Telemetry.duration ~key:"prechecked2_end" ~start_time
        |> Telemetry.object_ ~key:"prechecked2" ~value:prechecked2_telemetry
      in

      (* We might have completed a full check, which might mean that a rebase was
       * successfully processed. *)
      ServerRevisionTracker.check_non_blocking env;
      let telemetry =
        Telemetry.duration
          telemetry
          ~key:"revtrack4_check_non_blocking_end"
          ~start_time
      in

      let env =
        {
          env with
          typing_service =
            {
              delegate_state =
                Typing_service_delegate.stop env.typing_service.delegate_state;
              enabled = false;
            };
        }
      in
      let telemetry =
        Telemetry.duration telemetry ~key:"stop_typing_service" ~start_time
      in

      (* CAUTION! Lots of alerts/dashboards depend on this event, particularly start_t  *)
      let should_log =
        CheckKind.is_full || Float.(Unix.gettimeofday () -. start_time > 2.)
      in
      HackEventLogger.type_check_end
        (Option.some_if should_log telemetry)
        ~heap_size
        ~started_count:to_recheck_count
        ~total_rechecked_count
        ~experiments:genv.local_config.ServerLocalConfig.experiments
        ~desc:"serverTypeCheck"
        ~start_t:type_check_start_t;
      ( env,
        {
          CheckStats.reparse_count;
          total_rechecked_count;
          time_first_result = time_first_error;
        },
        telemetry )
  end

module FC = Make (FullCheckKind)
module LC = Make (LazyCheckKind)

let type_check_unsafe genv env kind start_time profiling =
  let check_kind = CheckKind.to_string kind in
  let check_reason =
    match (kind, env.ServerEnv.init_env.ServerEnv.why_needed_full_check) with
    | (CheckKind.Lazy, _) -> "keystroke"
    | (CheckKind.Full, Some init_telemetry) ->
      ServerEnv.Init_telemetry.get_reason init_telemetry
    | (CheckKind.Full, None) -> "incremental"
  in
  let telemetry =
    Telemetry.create ()
    |> Telemetry.string_ ~key:"kind" ~value:check_kind
    |> Telemetry.duration ~key:"start" ~start_time
  in

  (* CAUTION! Lots of alerts/dashboards depend on the exact string of check_kind and check_reason *)
  HackEventLogger.with_check_kind ~check_kind ~check_reason @@ fun () ->
  Hh_logger.log "******************************************";
  match kind with
  | CheckKind.Lazy ->
    Hh_logger.log
      "Check kind: will check only those files already open in IDE or with reported errors ('%s')"
      check_kind;
    let (_ : seconds option) =
      ServerBusyStatus.send ServerCommandTypes.Doing_local_typecheck
    in
    let telemetry =
      Telemetry.duration telemetry ~key:"core_start" ~start_time
    in
    let (env, stats, core_telemetry) =
      LC.type_check_core genv env start_time ~check_reason profiling
    in
    let telemetry =
      telemetry
      |> Telemetry.duration ~key:"core_end" ~start_time
      |> Telemetry.object_ ~key:"core" ~value:core_telemetry
    in
    let t_sent_done =
      ServerBusyStatus.send ServerCommandTypes.Done_local_typecheck
    in
    let stats = CheckStats.record_result_sent_ts stats t_sent_done in
    let telemetry = Telemetry.duration telemetry ~key:"sent_done" ~start_time in
    (env, stats, telemetry)
  | CheckKind.Full ->
    Hh_logger.log
      "Check kind: will bring hh_server to consistency with code changes, by checking whatever fanout is needed ('%s')"
      check_kind;
    let (_ : seconds option) =
      ServerBusyStatus.send
        (ServerCommandTypes.Doing_global_typecheck
           (ServerCheckUtils.global_typecheck_kind genv env))
    in
    let telemetry =
      Telemetry.duration telemetry ~key:"core_start" ~start_time
    in

    let (env, stats, core_telemetry) =
      FC.type_check_core genv env start_time ~check_reason profiling
    in

    let telemetry =
      telemetry
      |> Telemetry.duration ~key:"core_end" ~start_time
      |> Telemetry.object_ ~key:"core" ~value:core_telemetry
    in
    let t_sent_done =
      if is_full_check_done env.full_check_status then
        ServerBusyStatus.send ServerCommandTypes.Done_global_typecheck
      else
        None
    in
    let stats = CheckStats.record_result_sent_ts stats t_sent_done in
    let telemetry =
      telemetry |> Telemetry.duration ~key:"sent_done" ~start_time
    in
    (env, stats, telemetry)

let type_check :
    genv ->
    env ->
    CheckKind.t ->
    seconds ->
    CgroupProfiler.step_group ->
    env * CheckStats.t * Telemetry.t =
 fun genv env kind start_time cgroup_steps ->
  ServerUtils.with_exit_on_exception @@ fun () ->
  let type_check_result =
    type_check_unsafe genv env kind start_time cgroup_steps
  in
  type_check_result
