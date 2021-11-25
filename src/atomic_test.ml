open QCheck

(** This is a parallel test of the Atomic module *)

module CConf =
struct
  type cmd =
    | Get
    | Set of int
    | Exchange of int
    | Compare_and_set of int * int
    | Fetch_and_add of int
    | Incr
    | Decr [@@deriving show { with_path = false }]
  type state = int
  type sut = int Atomic.t

  let arb_cmd s =
    let int_gen = Gen.nat in
    QCheck.make ~print:show_cmd
      (Gen.oneof
         [Gen.return Get;
	  Gen.map (fun i -> Set i) int_gen;
	  Gen.map (fun i -> Exchange i) int_gen;
	  Gen.map (fun i -> Fetch_and_add i) int_gen;
	  Gen.map2 (fun seen v -> Compare_and_set (seen,v)) (Gen.oneof [Gen.return s; int_gen]) int_gen;
          Gen.return Incr;
	  Gen.return Decr;
         ])

  let init_state  = 0
  let init_sut () = Atomic.make 0
  let cleanup _   = ()

  let next_state c s = match c with
    | Get                      -> s
    | Set i                    -> i (*if i<>1213 then i else s*) (* an artificial fault *)
    | Exchange i               -> i
    | Fetch_and_add i          -> s+i
    | Compare_and_set (seen,v) -> if s=seen then v else s
    | Incr                     -> s+1
    | Decr                     -> s-1

  let precond _ _ = true

  type res =
    | RGet of int
    | RSet
    | RExchange of int
    | RFetch_and_add of int
    | RCompare_and_set of bool
    | RIncr
    | RDecr [@@deriving show { with_path = false }]

  let run c r = match c with
    | Get                      -> RGet (Atomic.get r)
    | Set i                    -> (Atomic.set r i; RSet)
    | Exchange i               -> RExchange (Atomic.exchange r i)
    | Fetch_and_add i          -> RFetch_and_add (Atomic.fetch_and_add r i)
    | Compare_and_set (seen,v) -> RCompare_and_set (Atomic.compare_and_set r seen v)
    | Incr                     -> (Atomic.incr r; RIncr)
    | Decr                     -> (Atomic.decr r; RDecr)

  let postcond c s res = match c,res with
    | Get,             RGet v           -> v = s (*&& v<>42*) (*an injected bug*)
    | Set _,           RSet             -> true
    | Exchange _,      RExchange v      -> v = s
    | Fetch_and_add _, RFetch_and_add v -> v = s
    | Compare_and_set (seen,_), RCompare_and_set b -> b = (s=seen)
    | Incr,            RIncr            -> true
    | Decr,            RDecr            -> true
    | _,_ -> false
end

module AT = STM.Make(CConf)

let agree_test_par ~count ~name =
  let seq_len = 20 in
  let par_len = 15 in
  Non_det.Test.make ~count ~name
    (AT.arb_cmds_par seq_len par_len) AT.agree_prop_par

let agree_test_pardomlib ~count ~name =
  let seq_len = 20 in
  let par_len = 15 in
  Non_det.Test.make ~count ~name
    (AT.arb_cmds_par seq_len par_len) AT.agree_prop_pardomlib
;;
Non_det.QCheck_runner.run_tests ~verbose:true [
    AT.agree_test           ~count:1000 ~name:"sequential atomic test";
    AT.agree_test_par       ~count:1000 ~name:"parallel atomic test (w/repeat)";
       agree_test_par       ~count:1000 ~name:"parallel atomic test (w/non_det module)";
    AT.agree_test_pardomlib ~count:1000 ~name:"parallel atomic test (w/Domainslib.Task and repeat)";
       agree_test_pardomlib ~count:1000 ~name:"parallel atomic test (w/Domainslib.Task and non_det module)";
  ]
