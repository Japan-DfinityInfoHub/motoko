module Fun =
struct
  let id x = x
  let flip f x y = f y x

  let curry f x y = f (x, y)
  let uncurry f (x, y) = f x y

  let rec repeat n f x =
    if n = 0 then () else (f x; repeat (n - 1) f x)
end

module Int =
struct
  let log2 n =
    if n <= 0 then failwith "log2";
    let rec loop acc n = if n = 1 then acc else loop (acc + 1) (n lsr 1) in
    loop 0 n

  let is_power_of_two n =
    if n < 0 then failwith "is_power_of_two";
    n <> 0 && n land (n - 1) = 0
end

module Uint32 =
struct
  type t = int32
  let of_string = Int32.of_string
  let to_string n = Printf.sprintf "%lu" n
  let add = Int32.add
  let sub = Int32.sub
  let mul = Int32.mul
  let succ = Int32.succ
  let zero = Int32.zero
  let one = Int32.one
  let of_int = Int32.of_int
  let to_int = Int32.to_int
  let logand = Int32.logand
  let logor = Int32.logor
  let shift_right_logical = Int32.shift_right_logical
  let of_int32 x = x
  let to_int32 x = x
  let compare i1 i2 =
    if i1 < 0l && i2 >= 0l then 1
    else if i1 >= 0l && i2 < 0l then -1
    else Int32.compare i1 i2
end

module String =
struct
  let implode cs =
    let buf = Buffer.create 80 in
    List.iter (Buffer.add_char buf) cs;
    Buffer.contents buf

  let explode s =
    let cs = ref [] in
    for i = String.length s - 1 downto 0 do cs := s.[i] :: !cs done;
    !cs

  let split s c =
    let len = String.length s in
    let rec loop i =
      if i > len then [] else
      let j = try String.index_from s i c with Not_found -> len in
      String.sub s i (j - i) :: loop (j + 1)
    in loop 0

  let breakup s n =
    let rec loop i =
      let len = min n (String.length s - i) in
      if len = 0 then [] else String.sub s i len :: loop (i + len)
    in loop 0

  let rec find_from_opt f s i =
    if i = String.length s then
      None
    else if f s.[i] then
      Some i
    else
      find_from_opt f s (i + 1)

  let chop_prefix prefix s =
    let prefix_len = String.length prefix in
    let s_len = String.length s in
    if s_len < prefix_len then
      None
    else if String.sub s 0 prefix_len = prefix then
      Some (String.sub s prefix_len (s_len - prefix_len))
    else
      None

  let chop_suffix suffix s =
    let suffix_len = String.length suffix in
    let s_len = String.length s in
    if s_len < suffix_len then
      None
    else if String.sub s (s_len - suffix_len) suffix_len = suffix then
      Some (String.sub s 0 (s_len - suffix_len))
    else
      None

  let lightweight_escaped str =
    let n = ref 0 in
    for i = 0 to String.length str - 1 do
      n := !n +
             (match str.[i] with
              | '\"' | '\'' | '\\' | '\n' | '\r' | '\b' | '\t' -> 2
              | _ -> 1)
    done;
    if !n = String.length str then str else begin
        let s' = Bytes.create !n in
        n := 0;
        for i = 0 to String.length str -1 do
          begin match str.[i] with
          | ('\"' | '\'' | '\\') as c ->
             Bytes.set s' !n '\\'; n := !n + 1; Bytes.set s' !n c
          | '\n' ->
             Bytes.set s' !n '\\'; n := !n + 1; Bytes.set s' !n 'n'
          | '\r' ->
             Bytes.set s' !n '\\'; n := !n + 1; Bytes.set s' !n 'r'
          | '\b' ->
             Bytes.set s' !n '\\'; n := !n + 1; Bytes.set s' !n 'b'
          | '\t' ->
             Bytes.set s' !n '\\'; n := !n + 1; Bytes.set s' !n 't'             
          | c -> Bytes.set s' !n c
          end;
          n := !n + 1
        done;
        Bytes.unsafe_to_string s'
      end    
end

module List =
struct
  let equal p xs ys =
    try List.for_all2 p xs ys with _ -> false

  let rec make n x = make' n x []
  and make' n x xs =
    if n = 0 then xs else make' (n - 1) x (x::xs)

  let rec table n f = table' n f []
  and table' n f xs =
    if n = 0 then xs else table' (n - 1) f (f (n - 1) :: xs)

  let group f l =
    let rec grouping acc = function
      | [] -> acc
      | hd::tl ->
         let l1,l2 = List.partition (f hd) tl in
         grouping ((hd::l1)::acc) l2
    in grouping [] l

  let rec take n xs =
    match n, xs with
    | _ when n <= 0 -> []
    | n, x::xs' when n > 0 -> x :: take (n - 1) xs'
    | _ -> failwith "take"

  let rec drop n xs =
    match n, xs with
    | 0, _ -> xs
    | n, _::xs' when n > 0 -> drop (n - 1) xs'
    | _ -> failwith "drop"

  let split_at n xs =
    if n <= List.length xs
    then (take n xs, drop n xs)
    else (xs, [])

  let hd_opt = function
    | x :: _ -> Some x
    | _ -> None

  let rec last = function
    | [x] -> x
    | _::xs -> last xs
    | [] -> failwith "last"

  let rec first_opt f = function
    | [] -> None
    | x::xs ->
       match f x with
       | None -> first_opt f xs
       | some -> some

  let rec split_last = function
    | [x] -> [], x
    | x::xs -> let ys, y = split_last xs in x::ys, y
    | [] -> failwith "split_last"

  let rec index_where p xs = index_where' p xs 0
  and index_where' p xs i =
    match xs with
    | [] -> None
    | x::xs' when p x -> Some i
    | x::xs' -> index_where' p xs' (i+1)

  let index_of x = index_where ((=) x)

  let rec map_filter f = function
    | [] -> []
    | x::xs ->
      match f x with
      | None -> map_filter f xs
      | Some y -> y :: map_filter f xs

  let rec compare f xs ys =
    match xs, ys with
    | [], [] -> 0
    | [], _ -> -1
    | _, [] -> +1
    | x::xs', y::ys' ->
      match f x y with
      | 0 -> compare f xs' ys'
      | n -> n

  let rec is_ordered f xs =
    match xs with
    | [] | [_] -> true
    | x1::x2::xs' ->
      match f x1 x2 with
      | -1 | 0 -> is_ordered f (x2::xs')
      | _ -> false

  let rec is_strictly_ordered f xs =
    match xs with
    | [] | [_] -> true
    | x1::x2::xs' ->
      match f x1 x2 with
      | -1 -> is_strictly_ordered f (x2::xs')
      | _ -> false

  let rec iter_pairs f = function
    | [] -> ()
    | x::ys -> List.iter (fun y -> f x y) ys; iter_pairs f ys
end

module List32 =
struct
  let rec make n x = make' n x []
  and make' n x xs =
    if n = 0l then xs else make' (Int32.sub n 1l) x (x::xs)

  let rec length xs = length' xs 0l
  and length' xs n =
    match xs with
    | [] -> n
    | _::xs' when n < Int32.max_int -> length' xs' (Int32.add n 1l)
    | _ -> failwith "length"

  let rec nth xs n =
    match n, xs with
    | 0l, x::_ -> x
    | n, _::xs' when n > 0l -> nth xs' (Int32.sub n 1l)
    | _ -> failwith "nth"

  let rec take n xs =
    match n, xs with
    | 0l, _ -> []
    | n, x::xs' when n > 0l -> x :: take (Int32.sub n 1l) xs'
    | _ -> failwith "take"

  let rec drop n xs =
    match n, xs with
    | 0l, _ -> xs
    | n, _::xs' when n > 0l -> drop (Int32.sub n 1l) xs'
    | _ -> failwith "drop"
end

module Array =
struct
  include Array

  let rec compare f x y = compare' f x y 0
  and compare' f x y i =
    match i = Array.length x, i = Array.length y with
    | true, true -> 0
    | true, false -> -1
    | false, true -> +1
    | false, false ->
      match f x.(i) y.(i) with
      | 0 -> compare' f x y (i + 1)
      | n -> n
end

module Array32 =
struct
  let make n x =
    if n < 0l || Int64.of_int32 n > Int64.of_int max_int then
      raise (Invalid_argument "Array32.make");
    Array.make (Int32.to_int n) x

  let length a = Int32.of_int (Array.length a)

  let index_of_int32 i =
    if i < 0l || Int64.of_int32 i > Int64.of_int max_int then -1 else
    Int32.to_int i

  let get a i = Array.get a (index_of_int32 i)
  let set a i x = Array.set a (index_of_int32 i) x
  let blit a1 i1 a2 i2 n =
    Array.blit a1 (index_of_int32 i1) a2 (index_of_int32 i2) (index_of_int32 n)
end

module Bigarray =
struct
  open Bigarray

  module Array1_64 =
  struct
    let create kind layout n =
      if n < 0L || n > Int64.of_int max_int then
        raise (Invalid_argument "Bigarray.Array1_64.create");
      Array1.create kind layout (Int64.to_int n)

    let dim a = Int64.of_int (Array1.dim a)

    let index_of_int64 i =
      if i < 0L || i > Int64.of_int max_int then -1 else
      Int64.to_int i

    let get a i = Array1.get a (index_of_int64 i)
    let set a i x = Array1.set a (index_of_int64 i) x
    let sub a i n = Array1.sub a (index_of_int64 i) (index_of_int64 n)
  end
end

module Option =
struct
  let equal p x y =
    match x, y with
    | Some x', Some y' -> p x' y'
    | None, None -> true
    | _, _ -> false

  let get o x =
    match o with
    | Some y -> y
    | None -> x

  let value = function
    | Some x -> x
    | None -> raise Not_found

  let map f = function
    | Some x -> Some (f x)
    | None -> None

  let iter f = function
    | Some x -> f x
    | None -> ()

  let some x = Some x

  let bind x f = match x with
    | Some x -> f x
    | None -> None

  let is_some x = x <> None

  let is_none x = x = None
end

module Promise =
struct
  type 'a t = 'a option ref

  exception Promise

  let make () = ref None
  let make_fulfilled x = ref (Some x)
  let fulfill p x = if !p = None then p := Some x else raise Promise
  let is_fulfilled p = !p <> None
  let value_opt p = !p
  let value p = match !p with Some x -> x | None -> raise Promise
end
