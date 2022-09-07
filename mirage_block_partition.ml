module type PARTITION_AT = sig
  (* XXX: should this be in bytes? in sectors?? *)
  val partition_at : int64
end

module Make(B : Mirage_block.S)(P : PARTITION_AT) = struct
  type t = {
    b : B.t;
    info : Mirage_block.info;
    (* inclusive *)
    sector_start : int64;
    (* inclusive *)
    sector_end : int64;
  }

  type nonrec error = [ 
    | `Block of B.error
    | `Out_of_bounds ]
  type nonrec write_error = [
    | `Block of B.write_error
    | `Out_of_bounds ]

  let pp_error ppf = function
    | `Block e -> B.pp_error ppf e
    | `Out_of_bounds -> Fmt.pf ppf "Operation out of partition bounds"

  let pp_write_error ppf = function
    | `Block e -> B.pp_write_error ppf e
    | `Out_of_bounds -> Fmt.pf ppf "Operation out of partition bounds"

  let get_info b =
    let size_sectors = Int64.(succ (sub b.sector_end b.sector_start)) in
    { b.info with size_sectors }

  let is_within b sector_start buffers =
    let buffers_len =
      buffers
      |> List.fold_left (fun acc cs -> acc + Cstruct.length cs) 0
      |> Int64.of_int
    in
    let num_sectors =
      Int64.(add 1L (div
                       (add buffers_len (pred (of_int b.info.sector_size)))
                       (of_int b.info.sector_size)))
    in
    let sector_start = Int64.add sector_start b.sector_start in
    sector_start >= b.info.size_sectors ||
    Int64.(add sector_start num_sectors) >= b.info.size_sectors

  let read b sector_start buffers =
    if is_within b sector_start buffers
    then
      B.read b.b (Int64.add b.sector_start sector_start) buffers
      |> Lwt_result.map_error (fun b -> `Block b)
    else
      Lwt.return (Error `Out_of_bounds)

  let write b sector_start buffers =
    if is_within b sector_start buffers
    then
      B.write b.b (Int64.add b.sector_start sector_start) buffers
      |> Lwt_result.map_error (fun b -> `Block b)
    else
      Lwt.return (Error `Out_of_bounds)

  let connect b =
    let ( let* ) = Lwt.bind in
    let* info = B.get_info b in
    let sector_start = 0L
    and sector_end = Int64.pred info.size_sectors in
    let sector_mid, misalignment =
      Int64.(div P.partition_at (of_int info.sector_size),
             rem P.partition_at (of_int info.sector_size))
    in
    if misalignment <> 0L then
      Lwt.return (Error ("Partition must be aligned with sector size " ^
                         Int64.to_string misalignment))
    else if sector_mid < sector_start || sector_mid > sector_end then
      Lwt.return (Error "Illegal partition point")
    else
      Lwt.return
        (Ok ({ b; info; sector_start; sector_end = sector_mid },
             { b; info; sector_start = Int64.succ sector_mid; sector_end }))

  let disconnect b =
    (* XXX disconnect both?! *)
    B.disconnect b.b
end