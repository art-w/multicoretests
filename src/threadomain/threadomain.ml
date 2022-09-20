open QCheck

(* We mix domains and threads. We use the name _node_ for either a
   domain or a thread *)

let swap arr i j =
  let x = arr.(i) in
  arr.(i) <- arr.(j) ;
  arr.(j) <- x

(** Generate a permutation of [0..size-1] *)
let permutation sz s =
  let arr = Array.init sz (fun x -> x) in
  for i = sz - 1 downto 1 do
    swap arr i (Gen.int_bound i s)
  done ;
  arr

(** Generate a tree of size nodes
 The tree is represented as an array [a] of integers, [a.(i)] being
 the parent of node [i]. Node [0] is the root of the tree.
 *)
let tree sz s =
  let parent i =
    if i == 0
    then -1
    else Gen.int_bound (i-1) s
  in
  Array.init sz parent

type worktype = Burn | Tak of int
  [@@deriving show { with_path = false }]

(** A test of spawn and join

    [spawn_tree] describes which domain/thread should spawn which other
    domains/threads
    [join_permutation] maps nodes to their position in the [join_tree]
    [join_tree] describes which domain/thread should wait on which
    other domains/threads
    [domain_or] describes whether a given node is a domain (true) or a
    thread (false)

    All those arrays should be of the same length, maybe an array of
    tuples would be a better choice, but make harder to read
*)
type spawn_join = {
  spawn_tree:       int array;
  join_permutation: int array;
  join_tree:        int array;
  domain_or:        bool array;
  workload:         worktype array
} [@@deriving show { with_path = false }]

(* Ensure that any domain is higher up in the join tree than all its
   threads, so that we cannot have a thread waiting on its domain even
   indirectly *)
let fix_permutation sz sj =
  let rec dom_of_thd i =
    let candidate = sj.spawn_tree.(i) in
    if candidate = -1 || sj.domain_or.(candidate)
    then candidate
    else dom_of_thd candidate
  in
  for i = 0 to sz-1 do
    if not sj.domain_or.(i) then
      let i' = sj.join_permutation.(i) in
      let d = dom_of_thd i in
      let d' = if d = -1 then d else sj.join_permutation.(d) in
      if d' > i' then swap sj.join_permutation i d
  done ;
  sj

let build_spawn_join sz spawn_tree join_permutation join_tree domain_or workload =
  fix_permutation sz { spawn_tree; join_permutation; join_tree; domain_or; workload }

let worktype =
  let open Gen in
  oneof [pure Burn; map (fun i -> Tak i) (int_bound 200)]

let gen_spawn_join sz =
  let open Gen in
  build_spawn_join sz
    <$> tree sz <*> permutation sz <*> tree sz
    <*> array_size (pure sz) (frequencyl [(1, true); (4, false)])
    <*> array_size (pure sz) worktype

type handle =
  | NoHdl
  | DomainHdl of unit Domain.t
  | ThreadHdl of Thread.t

(* All the node handles.
   Since they’ll be used to join, they are stored in join_permutation
   order *)
type handles = {
  handles: handle array;
  available: Semaphore.Binary.t array
}

let global = Atomic.make 0

let join_one hdls i =
  Semaphore.Binary.acquire hdls.available.(i) ;
  ( match hdls.handles.(i) with
    | NoHdl -> failwith "Semaphore acquired but no handle to join"
    | DomainHdl h -> ( Domain.join h ;
                       hdls.handles.(i) <- NoHdl )
    | ThreadHdl h -> ( Thread.join h ;
                       hdls.handles.(i) <- NoHdl ) )

(** In this first test each spawned domain calls [work] - and then optionally join. *)
(* a simple work item, from ocaml/testsuite/tests/misc/takc.ml *)
let rec tak x y z =
  if x > y then tak (tak (x-1) y z) (tak (y-1) z x) (tak (z-1) x y)
  else z

let rec burn l =
  if List.hd l > 12 then ()
  else
    burn (l @ l |> List.map (fun x -> x + 1))

let work w =
  match w with
  | Burn -> burn [8]
  | Tak i ->
    for _ = 1 to i do
      assert (7 = tak 18 12 6);
    done

let rec spawn_one sj hdls i =
  hdls.handles.(sj.join_permutation.(i)) <-
    if sj.domain_or.(i)
    then DomainHdl (Domain.spawn (run_node sj hdls i))
    else ThreadHdl (Thread.create (run_node sj hdls i) ()) ;
  Semaphore.Binary.release hdls.available.(sj.join_permutation.(i))

and run_node sj hdls i () =
  let sz = Array.length sj.spawn_tree in
  (* spawn nodes *)
  for j = i+1 to sz-1 do
    if sj.spawn_tree.(j) == i
    then spawn_one sj hdls j
  done ;
  Atomic.incr global ;
  work sj.workload.(i) ;
  (* join nodes *)
  let i' = sj.join_permutation.(i) in
  for j = i'+1 to sz-1 do
    if sj.join_tree.(j) == i'
    then join_one hdls j
  done

let run_all_nodes sj =
  let sz = Array.length sj.spawn_tree in
  let hdls = { handles = Array.make sz NoHdl;
               available = Array.init sz (fun _ -> Semaphore.Binary.make false) } in
  spawn_one sj hdls 0;
  join_one hdls 0;
  (* all the nodes should have been joined now *)
  Array.for_all (fun h -> h = NoHdl) hdls.handles
   && Atomic.get global = sz

let main_test = Test.make ~name:"Mash up of threads and domains"
                          ~count:1000
                          (make ~print:show_spawn_join (Gen.sized_size (Gen.int_range 2 100) gen_spawn_join))
                          (Util.fork_prop_with_timeout 1 run_all_nodes)

let _ =
  Util.set_ci_printing () ;
  QCheck_base_runner.run_tests_main [
    main_test
  ]
