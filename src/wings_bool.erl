%%
%%  wings_bool.erl --
%%
%%     This module implements bool commands for Wings objects.
%%
%%  Copyright (c) 2016 Dan Gudmundsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wings_bool).
-export([add/1]).

-include("wings.hrl").

-compile(export_all).

add(St0) ->
    MapBvh = wings_sel:fold(fun make_bvh/3, [], St0),
    IntScts = find_intersects(MapBvh, MapBvh, []),
    MFs = lists:append([MFL || #{fs:=MFL} <- IntScts]),
    Sel0 = sofs:relation(MFs, [{id,data}]),
    Sel1 = sofs:relation_to_family(Sel0),
    Sel2 = sofs:to_external(Sel1),
    Sel = [{Id,gb_sets:from_list(L)} || {Id,L} <- Sel2],
    io:format("~p~n", [Sel2]),
    wings_sel:set(face, Sel, St0).

find_intersects([Head|Tail], [_|_] = Alts, Acc) ->
    case find_intersect(Head, Alts) of
	false ->
	    find_intersects(Tail,Alts, Acc);
	{H1,Merge} ->
	    %% io:format("~p,~p => ~p~n", 
	    %% 	      [maps:get(id, Head), maps:get(id, H1), maps:get(fs,Merge)]),
	    NewTail = [Merge|remove(H1, Head, Tail)],
	    NewAlts = [Merge|remove(H1, Head, Tail)],
	    find_intersects(NewTail, NewAlts, [Merge|remove(Head,Acc)])
    end;
find_intersects(_, _, Acc) -> lists:reverse(Acc).

find_intersect(#{id:=Id}=Head, [#{id:=Id}|Rest]) ->
    find_intersect(Head, Rest);
find_intersect(#{bvh:=B1}=Head, [#{bvh:=B2}=H1|Rest]) ->
    case e3d_bvh:intersect(B1, B2) of
	[] ->  find_intersect(Head,Rest);
	EdgeInfo -> {H1, merge(EdgeInfo, Head, H1)}
    end;
find_intersect(_Head, []) ->
    false.

merge(EdgeInfo, #{id:=Id1,fs:=Fs1}=I1, #{id:=Id2,fs:=Fs2}=I2) ->
    ReEI = [remap(Edge, I1, I2) || Edge <- EdgeInfo, min_length(Edge)],
    KD3 = make_kd3(ReEI),
    io:format("~p~n", [KD3]),
    VLoops0 = build_vtx_loops(KD3, []),
    io:format("~p~n", [[pick(E) || E <- hd(VLoops0)]]),
    _VLoops1 = [loop_we(Loop, Id1) || Loop <- VLoops0],
    _VLoops2 = [loop_we(Loop, Id2) || Loop <- VLoops0],
    %% io:format("Loop ~p: ~p~n", [Id1, _VLoops1]),
    %% io:format("Loop ~p: ~p~n", [Id2, _VLoops2]),
    MFs = lists:flatten([[MF1,MF2] || #{mf1:=MF1,other:=MF2} <- ReEI]),
    I1#{id:=min(Id1,Id2),fs:=Fs1++Fs2++MFs}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

make_bvh(_, #we{id=Id, fs=Fs0}=We0, Bvhs) ->
    Fs = gb_trees:keys(Fs0),
    {Vtab,Ts} = triangles(Fs, We0),
    Get = fun({verts, Face}) -> element(1, array:get(Face, Ts));
	     (verts) -> Vtab;
	     (meshId) -> Id
	  end,
    Bvh = e3d_bvh:init([{array:size(Ts), Get}]),
    [#{id=>Id,map=>Ts,bvh=>Bvh,fs=>[], we=>We0}|Bvhs].

make_kd3(Edges) ->
    Ps = lists:foldl(fun(#{p1:=P1,p2:=P2}=EI, Acc) ->
			     [{P1, EI}, {P2, EI}|Acc]
		     end, [], Edges),
    e3d_kd3:from_list(Ps).

min_length(#{p1:=P1,p2:=P2}=_Edge) ->
    Dist2 = e3d_vec:dist_sqr(P1,P2),
    %% io:format("~p ~p~n", [Edge, Dist2]),
    Dist2 > 1.0e-15.

loop_we(Loop, Id) ->
    [loop_we_1(EdgeI, Id) || EdgeI <- Loop].

loop_we_1({Point, #{mf1:=MF1, other:={_, F2}}}, Id) ->
    case MF1 of
	{Id, Face} -> {Face, Point};
	_ -> {F2, Point}
    end.

build_vtx_loops(KD30, Acc) ->
    case e3d_kd3:take_nearest({1.0e23,1.0e23,1.0e23}, KD30) of
	undefined -> Acc;
	{{_,Edge}=First, KD31} ->
	    {P1,{Pos,_}=P2} = pick(First),
	    KD32 = e3d_kd3:delete_object({Pos,Edge}, KD31),
	    {Loop, KD33} = build_vtx_loop(P2, P1, KD32, [First]),
	    build_vtx_loops(KD33, [Loop|Acc])
    end.

build_vtx_loop({Pos,MF1}=Search, Start, KD30, Acc) ->
    io:format("~p~n",[Search]),
    case e3d_kd3:take_nearest(Pos, KD30) of
	{{_,Edge}=Next,KD31} ->
	    case pick(Next) of
		{{_,MF1}, {Pos2,_} = P2} ->
		    KD32 = e3d_kd3:delete_object({Pos2,Edge}, KD31),
		    build_vtx_loop(P2, Start, KD32, [Next|Acc]);
		{_, {Pos2,_} = P2} ->
		    %% Wrong face, see if there is better alternative
		    KD32 = e3d_kd3:delete_object({Pos2,Edge}, KD31),
		    case e3d_kd3:take_nearest(Pos, KD32) of
			{{_,Edge2}=Next2,_} ->
			    case pick(Next2) of
				{{Pos11,MF1}, {Pos21,_} = P21} ->
				    KD33 = e3d_kd3:delete_object({Pos11,Edge2}, KD30),
				    KD34 = e3d_kd3:delete_object({Pos21,Edge2}, KD33),
				    build_vtx_loop(P21, Start, KD34, [Next2|Acc]);
				_ ->
				    KD32 = e3d_kd3:delete_object({Pos2,Edge}, KD31),
				    build_vtx_loop(P2, Start, KD32, [Next|Acc])
			    end;
			_ ->
			    KD32 = e3d_kd3:delete_object({Pos2,Edge}, KD31),
			    build_vtx_loop(P2, Start, KD32, [Next|Acc])
		    end
	    end;
	undefined ->
	    {Acc, KD30}
    end.

pick({P1, #{p1:=P1,mf1:=MF1,p2:=P2,mf2:=MF2}}) -> {{P1,MF1},{P2,MF2}};
pick({P2, #{p1:=P1,mf1:=MF1,p2:=P2,mf2:=MF2}}) -> {{P2,MF2},{P1,MF1}}.

pick({_, #{p1:=P1,p2:=P2}}, Search) ->
    case e3d_vec:dist_sqr(P1, Search) < e3d_vec:dist_sqr(P2, Search) of
	true  -> {P1,P2};
	false -> {P2,P1}
    end.

remove(#{id:=Id}, List) ->
    Map = mapsfind(Id, id, List),
    lists:delete(Map, List).

remove(H1, H2, List) ->
    remove(H1, remove(H2, List)).

remap(#{mf1:=MF1,mf2:=MF2,other:=Other}=Edge,
      #{id:=Id1,map:=M1}, #{id:=Id2,map:=M2}) ->
    Edge#{mf1:=remap_1(MF1, Id1, M1, Id2, M2),
	  mf2:=remap_1(MF2, Id1, M1, Id2, M2),
	  other:=remap_1(Other, Id1, M1, Id2, M2)}.

remap_1({Id, TriFace}, Id, M1, _Id2, _M2) ->
    {_, Face} = array:get(TriFace, M1),
    {Id, Face};
remap_1({Id, TriFace}, _Id, _M1, Id, M2) ->
    {_, Face} = array:get(TriFace, M2),
    {Id, Face}.

%% Use wings_util:mapsfind
mapsfind(Value, Key, [H|T]) ->
    case H of
	#{Key:=Value} -> H;
	_ -> mapsfind(Value, Key, T)
    end;
mapsfind(_, _, []) -> false.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

triangles(Fs, We0) ->
    {#we{vp=Vtab}, Ts} = lists:foldl(fun triangle/2, {We0,[]}, Fs),
    {Vtab, array:from_list(Ts)}.

triangle(Face, {We, Acc}) ->
    Vs = wings_face:vertices_ccw(Face, We),
    case length(Vs) of
	3 -> {We, [{list_to_tuple(Vs), Face}|Acc]};
	4 -> tri_quad(Vs, We, Face, Acc);
	_ -> tri_poly(Vs, We, Face, Acc)
    end.

tri_quad([Ai,Bi,Ci,Di] = Vs, #we{vp=Vtab}=We, Face, Acc) ->
    [A,B,C,D] = VsPos = [array:get(V, Vtab) || V <- Vs],
    N = e3d_vec:normal(VsPos),
    case wings_tesselation:is_good_triangulation(N, A, B, C, D) of
	true  -> {We, [{{Ai,Bi,Ci}, Face}, {{Ai,Ci,Di}, Face}|Acc]};
	false -> {We, [{{Ai,Bi,Di}, Face}, {{Bi,Ci,Di}, Face}|Acc]}
    end.

tri_poly(Vs, #we{vp=Vtab}=We, Face, Acc0) ->
    VsPos = [array:get(V, Vtab) || V <- Vs],
    N = e3d_vec:normal(VsPos),
    {Fs0, Ps0} = wings_gl:triangulate(N, VsPos),
    Index = array:size(Vtab),
    {TessVtab, Is} = renumber_and_add_vs(Ps0, Vs, Index, Vtab, []),
    Fs = lists:foldl(fun({A,B,C}, Acc) ->
			     F = {element(A,Is), element(B, Is), element(C,Is)},
			     [{F, Face}|Acc]
		     end, Acc0, Fs0),
    {We#we{vp=TessVtab}, Fs}.

renumber_and_add_vs([_|Ps], [V|Vs], Index, Vtab, Acc) ->
    renumber_and_add_vs(Ps, Vs, Index, Vtab, [V|Acc]);
renumber_and_add_vs([Pos|Ps], [], Index, Vtab0, Acc) ->
    Vtab = array:add(Index, Pos, Vtab0),
    renumber_and_add_vs(Ps, [], Index+1, Vtab, [Index|Acc]);
renumber_and_add_vs([], [], _, Vtab, Vs) ->
    {Vtab, list_to_tuple(lists:reverse(Vs))}.

