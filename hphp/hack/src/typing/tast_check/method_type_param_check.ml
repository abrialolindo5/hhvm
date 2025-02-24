(*
 * Copyright (c) 2018, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Hh_prelude
open Aast

let check_tparams tps =
  let check_tparam tp =
    match tp.tp_variance with
    | Ast_defs.Invariant -> ()
    | _ ->
      Errors.add_typing_error
        Typing_error.(primary @@ Primary.Method_variance (fst tp.tp_name))
  in
  List.iter tps ~f:check_tparam

let handler =
  object
    inherit Tast_visitor.handler_base

    method! at_method_ _ m = check_tparams m.m_tparams

    method! at_fun_def _ fd = check_tparams fd.fd_tparams
  end
