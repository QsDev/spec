(*
 * (c) 2015 Andreas Rossberg
 *)

open Bigarray
open Types
open Values

type address = int64
type size = address
type mem_size = Mem8 | Mem16 | Mem32
type extension = SX | ZX
type segment = {addr : address; data : string}
type value_type = Types.value_type
type value = Values.value

type memory' = (int, int8_unsigned_elt, c_layout) Array1.t
type memory = memory' ref
type t = memory

exception Type
exception Bounds
exception Address

(*
 * These limitations should be considered part of the host environment and not
 * part of the spec defined by this file.
 * ==========================================================================
 *)

let host_size_of_int64 n =
  if n < Int64.zero || n > (Int64.of_int max_int) then raise Out_of_memory;
  Int64.to_int n

let int64_of_host_size n =
  Int64.of_int n

let host_index_of_int64 a n =
  assert (n >= 0);
  let n' = Int64.of_int n in
  if (a < Int64.zero) ||
     (Int64.sub Int64.max_int a < n') ||
     (Int64.add a n' > Int64.of_int max_int) then raise Bounds;
  Int64.to_int a

(* ========================================================================== *)


let create' n =
  let sz = host_size_of_int64 n in
  let mem = Array1.create Int8_unsigned C_layout sz in
  Array1.fill mem 0;
  mem

let create n =
  ref (create' n)

let init_seg mem seg =
  (* There currently is no way to blit from a string. *)
  let n = String.length seg.data in
  let base = host_index_of_int64 seg.addr n in
  for i = 0 to n - 1 do
    !mem.{base + i} <- Char.code seg.data.[i]
  done

let init mem segs =
  try List.iter (init_seg mem) segs with Invalid_argument _ -> raise Bounds

let size mem =
  int64_of_host_size (Array1.dim !mem)

let resize mem n =
  let after = create' n in
  let min = host_index_of_int64 (min (size mem) n) 0 in
  Array1.blit (Array1.sub !mem 0 min) (Array1.sub after 0 min);
  mem := after

let rec loadn mem n a =
  assert (n > 0 && n <= 8);
  let i = host_index_of_int64 a n in
  try loadn' mem n i with Invalid_argument _ -> raise Bounds

and loadn' mem n i =
  let byte = Int64.of_int !mem.{i} in
  if n = 1 then
    byte
  else
    Int64.logor byte (Int64.shift_left (loadn' mem (n-1) (i+1)) 8)

let rec storen mem n a v =
  assert (n > 0 && n <= 8);
  let i = host_index_of_int64 a n in
  try storen' mem n i v with Invalid_argument _ -> raise Bounds

and storen' mem n i v =
  !mem.{i} <- (Int64.to_int v) land 255;
  if (n > 1) then
    storen' mem (n-1) (i+1) (Int64.shift_right v 8)

let load mem a t =
  match t with
  | Int32Type -> Int32 (Int64.to_int32 (loadn mem 4 a))
  | Int64Type -> Int64 (loadn mem 8 a)
  | Float32Type -> Float32 (F32.of_bits (Int64.to_int32 (loadn mem 4 a)))
  | Float64Type -> Float64 (F64.of_bits (loadn mem 8 a))

let store mem a v =
  match v with
  | Int32 x -> storen mem 4 a (Int64.of_int32 x)
  | Int64 x -> storen mem 8 a x
  | Float32 x -> storen mem 4 a (Int64.of_int32 (F32.to_bits x))
  | Float64 x -> storen mem 8 a (F64.to_bits x)

let loadn_sx mem n a =
  assert (n > 0 && n <= 8);
  let v = loadn mem n a in
  let shift = 64 - (8 * n) in
  Int64.shift_right (Int64.shift_left v shift) shift

let load_extend mem a sz ext t =
  match sz, ext, t with
  | Mem8,  ZX, Int32Type -> Int32 (Int64.to_int32 (loadn    mem 1 a))
  | Mem8,  SX, Int32Type -> Int32 (Int64.to_int32 (loadn_sx mem 1 a))
  | Mem8,  ZX, Int64Type -> Int64 (loadn mem 1 a)
  | Mem8,  SX, Int64Type -> Int64 (loadn_sx mem 1 a)
  | Mem16, ZX, Int32Type -> Int32 (Int64.to_int32 (loadn    mem 2 a))
  | Mem16, SX, Int32Type -> Int32 (Int64.to_int32 (loadn_sx mem 2 a))
  | Mem16, ZX, Int64Type -> Int64 (loadn    mem 2 a)
  | Mem16, SX, Int64Type -> Int64 (loadn_sx mem 2 a)
  | Mem32, ZX, Int64Type -> Int64 (loadn    mem 4 a)
  | Mem32, SX, Int64Type -> Int64 (loadn_sx mem 4 a)
  | _ -> raise Type

let store_wrap mem a sz v =
  match sz, v with
  | Mem8,  Int32 x -> storen mem 1 a (Int64.of_int32 x)
  | Mem8,  Int64 x -> storen mem 1 a x
  | Mem16, Int32 x -> storen mem 2 a (Int64.of_int32 x)
  | Mem16, Int64 x -> storen mem 2 a x
  | Mem32, Int64 x -> storen mem 4 a x
  | _ -> raise Type
