apply(ipfwd,
        (ip_dst#32,),
	({\ (v#9) -> out:=v#9})
	{skip});
apply(tunnel,
        (tunnel_valid#1,tunnel_id#9,),
	( {\ (v#9, t#9) -> out := v#9; tunnel_id:= t#9}),
	{skip})
	