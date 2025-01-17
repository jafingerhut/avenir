apply(l3_fwd,
     (ipv6_dst#128, ipv6_src#128, ipv6_next_header#8,),
     ( {\ (port#9,) -> out_port := port#9;
                       if ordered
		          ipv6_hop_count#8 = 0#8 -> ipv6_hop_count := 0#8 []
			  true -> ipv6_hop_count := ipv6_hop_count#8 - 1#8 []
		       fi }),
		      
     {out_port := 0#9});

apply(punt,
     (ipv6_hop_count#8,),
     ({ \ (port_punt#9,) -> out_port := port_punt#9 }),
     {skip});

if ordered
  out_port#9 = 0#9 ->
      ipv6_dst := 0#128;
      ipv6_src := 0#128;
      ipv6_next_header := 0#8;
      ipv6_hop_count := 0#8 []
   true -> skip []
fi