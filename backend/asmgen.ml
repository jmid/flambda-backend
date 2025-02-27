(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* From lambda to assembly code *)

[@@@ocaml.warning "+a-4-9-40-41-42"]

open Format
open Config
open Clflags
open Misc
open Cmm

type error =
  | Assembler_error of string
  | Mismatched_for_pack of string option

exception Error of error

let cmm_invariants ppf fd_cmm =
  let print_fundecl =
    if !Clflags.dump_cmm then Printcmm.fundecl
    else fun ppf fdecl -> Format.fprintf ppf "%s" fdecl.fun_name
  in
  if !Clflags.cmm_invariants && Cmm_invariants.run ppf fd_cmm then
    Misc.fatal_errorf "Cmm invariants failed on following fundecl:@.%a@."
      print_fundecl fd_cmm;
  fd_cmm

let liveness phrase = Liveness.fundecl phrase; phrase

let dump_if ppf flag message phrase =
  if !flag then Printmach.phase message ppf phrase

let pass_dump_if ppf flag message phrase =
  dump_if ppf flag message phrase; phrase

let pass_dump_linear_if ppf flag message phrase =
  if !flag then fprintf ppf "*** %s@.%a@." message Printlinear.fundecl phrase;
  phrase

let pass_dump_cfg_if ppf flag message c =
  if !flag then
    fprintf ppf "*** %s@.%a@." message (Cfg_with_layout.dump ~msg:"") c;
  c

let start_from_emit = ref true

let should_save_before_emit () =
  should_save_ir_after Compiler_pass.Scheduling && (not !start_from_emit)

let linear_unit_info =
  { Linear_format.unit_name = "";
    items = [];
    for_pack = None;
  }

let reset () =
  start_from_emit := false;
  if should_save_before_emit () then begin
    linear_unit_info.unit_name <- Compilenv.current_unit_name ();
    linear_unit_info.items <- [];
    linear_unit_info.for_pack <- !Clflags.for_package;
  end

let save_data dl =
  if should_save_before_emit () then begin
    linear_unit_info.items <- Linear_format.(Data dl) :: linear_unit_info.items
  end;
  dl

let save_linear f =
  if should_save_before_emit () then begin
    linear_unit_info.items <- Linear_format.(Func f) :: linear_unit_info.items
  end;
  f

let write_linear prefix =
  if should_save_before_emit () then begin
    let filename = Compiler_pass.(to_output_filename Scheduling ~prefix) in
    linear_unit_info.items <- List.rev linear_unit_info.items;
    Linear_format.save filename linear_unit_info
  end

let should_emit () =
  not (should_stop_after Compiler_pass.Scheduling)

let if_emit_do f x = if should_emit () then f x else ()
let emit_begin_assembly = if_emit_do Emit.begin_assembly
let emit_end_assembly = if_emit_do Emit.end_assembly
let emit_data = if_emit_do Emit.data
let emit_fundecl =
  if_emit_do
    (Profile.record ~accumulate:true "emit" Emit.fundecl)

let rec regalloc ~ppf_dump round fd =
  if round > 50 then
    fatal_error(fd.Mach.fun_name ^
                ": function too complex, cannot complete register allocation");
  dump_if ppf_dump dump_live "Liveness analysis" fd;
  let num_stack_slots =
    if !use_linscan then begin
      (* Linear Scan *)
      Interval.build_intervals fd;
      if !dump_interval then Printmach.intervals ppf_dump ();
      Linscan.allocate_registers()
    end else begin
      (* Graph Coloring *)
      Interf.build_graph fd;
      if !dump_interf then Printmach.interferences ppf_dump ();
      if !dump_prefer then Printmach.preferences ppf_dump ();
      Coloring.allocate_registers()
    end
  in
  dump_if ppf_dump dump_regalloc "After register allocation" fd;
  let (newfd, redo_regalloc) = Reload.fundecl fd num_stack_slots in
  dump_if ppf_dump dump_reload "After insertion of reloading code" newfd;
  if redo_regalloc then begin
    Reg.reinit(); Liveness.fundecl newfd; regalloc ~ppf_dump (round + 1) newfd
  end else newfd

let (++) x f = f x

let ocamlcfg_verbose =
  match Sys.getenv_opt "OCAMLCFG_VERBOSE" with
  | Some "1" -> true
  | Some _ | None -> false

let test_cfgize (f : Mach.fundecl) (res : Linear.fundecl) : unit =
  if ocamlcfg_verbose then begin
    Format.eprintf "processing function %s...\n%!" f.Mach.fun_name;
  end;
  let result =
    Cfgize.fundecl
      f
      ~preserve_orig_labels:false
      ~simplify_terminators:true
  in
  let expected = Linear_to_cfg.run res ~preserve_orig_labels:false in
  Eliminate_fallthrough_blocks.run expected;
  Merge_straightline_blocks.run expected;
  Eliminate_dead_blocks.run expected;
  Simplify_terminator.run (Cfg_with_layout.cfg expected);
  Cfg_equivalence.check_cfg_with_layout f expected result;
  if ocamlcfg_verbose then begin
    Format.eprintf "the CFG on both code paths are equivalent for function %s.\n%!"
      f.Mach.fun_name;
  end

let compile_fundecl ~ppf_dump fd_cmm =
  Proc.init ();
  Reg.reset();
  fd_cmm
  ++ Profile.record ~accumulate:true "cmm_invariants" (cmm_invariants ppf_dump)
  ++ Profile.record ~accumulate:true "selection" Selection.fundecl
  ++ pass_dump_if ppf_dump dump_selection "After instruction selection"
  ++ Profile.record ~accumulate:true "comballoc" Comballoc.fundecl
  ++ pass_dump_if ppf_dump dump_combine "After allocation combining"
  ++ Profile.record ~accumulate:true "cse" CSE.fundecl
  ++ pass_dump_if ppf_dump dump_cse "After CSE"
  ++ Profile.record ~accumulate:true "liveness" liveness
  ++ Profile.record ~accumulate:true "deadcode" Deadcode.fundecl
  ++ pass_dump_if ppf_dump dump_live "Liveness analysis"
  ++ Profile.record ~accumulate:true "spill" Spill.fundecl
  ++ Profile.record ~accumulate:true "liveness" liveness
  ++ pass_dump_if ppf_dump dump_spill "After spilling"
  ++ Profile.record ~accumulate:true "split" Split.fundecl
  ++ pass_dump_if ppf_dump dump_split "After live range splitting"
  ++ Profile.record ~accumulate:true "liveness" liveness
  ++ Profile.record ~accumulate:true "regalloc" (regalloc ~ppf_dump 1)
  ++ Profile.record ~accumulate:true "available_regs" Available_regs.fundecl
  ++ Profile.record ~accumulate:true "linearize" (fun (f : Mach.fundecl) ->
      let res = Linearize.fundecl f in
      (* CR xclerc for xclerc: temporary, for testing. *)
      if !Clflags.use_ocamlcfg then begin
        test_cfgize f res;
      end;
      res)
  ++ pass_dump_linear_if ppf_dump dump_linear "Linearized code"
  ++ (fun (fd : Linear.fundecl) ->
    if !use_ocamlcfg then begin
      fd
      ++ Profile.record ~accumulate:true "linear_to_cfg"
           (Linear_to_cfg.run ~preserve_orig_labels:true)
      ++ pass_dump_cfg_if ppf_dump dump_cfg "After linear_to_cfg"
      ++ Profile.record ~accumulate:true "cfg_to_linear" Cfg_to_linear.run
      ++ pass_dump_linear_if ppf_dump dump_linear "After cfg_to_linear"
    end else
      fd)
  ++ Profile.record ~accumulate:true "scheduling" Scheduling.fundecl
  ++ pass_dump_linear_if ppf_dump dump_scheduling "After instruction scheduling"
  ++ save_linear
  ++ emit_fundecl

let compile_data dl =
  dl
  ++ save_data
  ++ emit_data

let compile_phrase ~ppf_dump p =
  if !dump_cmm then fprintf ppf_dump "%a@." Printcmm.phrase p;
  match p with
  | Cfunction fd -> compile_fundecl ~ppf_dump fd
  | Cdata dl -> compile_data dl


(* For the native toplevel: generates generic functions unless
   they are already available in the process *)
let compile_genfuns ~ppf_dump f =
  List.iter
    (function
       | (Cfunction {fun_name = name}) as ph when f name ->
           compile_phrase ~ppf_dump ph
       | _ -> ())
    (Cmm_helpers.generic_functions true [Compilenv.current_unit_infos ()])

let compile_unit ~output_prefix ~asm_filename ~keep_asm ~obj_filename gen =
  reset ();
  let create_asm = should_emit () &&
                   (keep_asm || not !Emitaux.binary_backend_available) in
  Emitaux.create_asm_file := create_asm;
  Misc.try_finally
    ~exceptionally:(fun () -> remove_file obj_filename)
    (fun () ->
       if create_asm then Emitaux.output_channel := open_out asm_filename;
       Misc.try_finally
         (fun () ->
            gen ();
            write_linear output_prefix)
         ~always:(fun () ->
             if create_asm then close_out !Emitaux.output_channel)
         ~exceptionally:(fun () ->
             if create_asm && not keep_asm then remove_file asm_filename);
       if should_emit () then begin
         let assemble_result =
           Profile.record "assemble"
             (Proc.assemble_file asm_filename) obj_filename
         in
         if assemble_result <> 0
         then raise(Error(Assembler_error asm_filename));
       end;
       if create_asm && not keep_asm then remove_file asm_filename
    )

let end_gen_implementation0 ?toplevel ~ppf_dump make_cmm =
  emit_begin_assembly ();
  make_cmm ()
  ++ Profile.record "compile_phrases" (List.iter (compile_phrase ~ppf_dump))
  ++ (fun () -> ());
  (match toplevel with None -> () | Some f -> compile_genfuns ~ppf_dump f);
  (* We add explicit references to external primitive symbols.  This
     is to ensure that the object files that define these symbols,
     when part of a C library, won't be discarded by the linker.
     This is important if a module that uses such a symbol is later
     dynlinked. *)
  compile_phrase ~ppf_dump
    (Cmm_helpers.reference_symbols
       (List.filter_map (fun prim ->
           if not (Primitive.native_name_is_external prim) then None
           else Some (Primitive.native_name prim))
          !Translmod.primitive_declarations));
  emit_end_assembly ()

let end_gen_implementation ?toplevel ~ppf_dump clambda =
  end_gen_implementation0 ?toplevel ~ppf_dump (fun () ->
    Profile.record "cmm" Cmmgen.compunit clambda)

type middle_end =
     backend:(module Backend_intf.S)
  -> filename:string
  -> prefixname:string
  -> ppf_dump:Format.formatter
  -> Lambda.program
  -> Clambda.with_constants

let asm_filename output_prefix =
    if !keep_asm_file || !Emitaux.binary_backend_available
    then output_prefix ^ ext_asm
    else Filename.temp_file "camlasm" ext_asm

let compile_implementation ?toplevel ~backend ~filename ~prefixname ~middle_end
      ~ppf_dump (program : Lambda.program) =
  compile_unit ~output_prefix:prefixname
    ~asm_filename:(asm_filename prefixname) ~keep_asm:!keep_asm_file
    ~obj_filename:(prefixname ^ ext_obj)
    (fun () ->
      Ident.Set.iter Compilenv.require_global program.required_globals;
      let clambda_with_constants =
        middle_end ~backend ~filename ~prefixname ~ppf_dump program
      in
      end_gen_implementation ?toplevel ~ppf_dump clambda_with_constants)

type middle_end_flambda2 =
     ppf_dump:Format.formatter
  -> prefixname:string
  -> backend:(module Flambda2__Flambda_backend_intf.S)
  -> filename:string
  -> module_ident:Ident.t
  -> module_block_size_in_words:int
  -> module_initializer:Lambda.lambda
  -> Flambda2__Flambda_middle_end.middle_end_result

let compile_implementation_flambda2 ?toplevel ~backend ~filename ~prefixname
    ~size:module_block_size_in_words ~module_ident ~module_initializer
    ~(middle_end : middle_end_flambda2) ~flambda2_to_cmm ~ppf_dump
    ~required_globals () =
  compile_unit ~output_prefix:prefixname
    ~asm_filename:(asm_filename prefixname) ~keep_asm:!keep_asm_file
    ~obj_filename:(prefixname ^ ext_obj)
    (fun () ->
      Ident.Set.iter Compilenv.require_global required_globals;
      let middle_end_result =
        middle_end ~backend ~module_block_size_in_words ~filename ~prefixname
          ~ppf_dump ~module_ident ~module_initializer
      in
      let cmm_phrases = flambda2_to_cmm middle_end_result in
      end_gen_implementation0 ?toplevel ~ppf_dump (fun () -> cmm_phrases))

let linear_gen_implementation filename =
  let open Linear_format in
  let linear_unit_info, _ = restore filename in
  (match !Clflags.for_package, linear_unit_info.for_pack with
   | None, None -> ()
   | Some expected, Some saved when String.equal expected saved -> ()
   | _, saved -> raise(Error(Mismatched_for_pack saved)));
  let emit_item = function
    | Data dl -> emit_data dl
    | Func f -> emit_fundecl f
  in
  start_from_emit := true;
  emit_begin_assembly ();
  Profile.record "Emit" (List.iter emit_item) linear_unit_info.items;
  emit_end_assembly ()

let compile_implementation_linear output_prefix ~progname =
  compile_unit ~output_prefix
    ~asm_filename:(asm_filename output_prefix) ~keep_asm:!keep_asm_file
    ~obj_filename:(output_prefix ^ ext_obj)
    (fun () ->
      linear_gen_implementation progname)

(* Error report *)

let report_error ppf = function
  | Assembler_error file ->
      fprintf ppf "Assembler error, input left in file %a"
        Location.print_filename file
  | Mismatched_for_pack saved ->
    let msg = function
       | None -> "without -for-pack"
       | Some s -> "with -for-pack "^s
     in
     fprintf ppf
       "This input file cannot be compiled %s: it was generated %s."
       (msg !Clflags.for_package) (msg saved)

let () =
  Location.register_error_of_exn
    (function
      | Error err -> Some (Location.error_of_printer_file report_error err)
      | _ -> None
    )
