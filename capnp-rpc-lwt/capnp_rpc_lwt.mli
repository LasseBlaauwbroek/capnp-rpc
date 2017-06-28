type 'a or_error = ('a, Capnp_rpc.Error.t) result

module StructRef : sig
  type 'a t
  (** An ['a t] is a reference to a response message (that may not have arrived yet)
      with content type ['a]. *)

  val finish : 'a t -> unit
  (** [finish t] indicates that this result will never be used again.
      If the results have not yet arrived, we send a cancellation request (which
      may or may not succeed). As soon as the results are available, they are
      released. It is an error to use [t] after calling this. *)
end

module rec Payload : sig
  type 'a t
  (** An ['a t] is a request or response payload: a struct and a cap table.
      To read the struct, use the one of the generated [_of_payload] methods. *)

  type 'a index = private Uint32.t

  val import : 'a t -> 'b index -> 'b Capability.t
  (** [import t i] is the capability at index [i] in the table.
      Use the generated field accessors to get [i].
      This increases the ref-count on the capability - call [dec_ref] when done with it. *)

  val release : 'a t -> unit
  (** [release t] releases the payload, by reducing the ref-count on each capability in it. *)
end

and Capability : sig
  type 'a t
  (** An ['a t] is a capability reference to a service of type ['a]. *)

  type 'a capability_t = 'a t (* (alias because we have too many t's) *)

  type ('t, 'a, 'b) method_t
  (** A method on some instance, as seen by the client application code. *)

  module Request : sig
    type 'a t
    (** An ['a t] is a builder for the out-going request's payload. *)

    val create : (Capnp.Message.rw Capnp.BytesMessage.Slice.t -> 'a) -> 'a t * 'a
    (** [create init] is a fresh request payload and contents builder.
        Use one of the generated [init_pointer] functions for [init]. *)

    val create_no_args : unit -> 'a t
    (** [create_no_args ()] is a payload with no content. *)

    val export : 'a t -> 'b capability_t -> 'b Payload.index
    (** [export t cap] adds [cap] to the payload's CapDescriptor table and returns
        its index. You can use the index with the generated setter.
        The request increases the ref-count on [cap]. If you decide not to send
        the message, use [release] to free it. *)

    val release : 'a t -> unit
    (** Clear the exported refs, dropping their ref-counts. This is called automatically
        when you send a message, but you might need it if you decide to abort. *)
  end

  val call : 't capability_t -> ('t, 'a, 'b) method_t -> 'a Request.t -> 'b StructRef.t
  (** [call m req] invokes [m req] and returns a promise for the result.
      Messages may be sent to the capabilities that will be in the result
      before the result arrives - they will be pipelined to the service
      responsible for resolving the promise. *)

  val call_for_value : 't capability_t -> ('t, 'a, 'b) method_t -> 'a Request.t -> 'b Payload.t or_error Lwt.t
  (** [call_for_value m req] invokes [m ret] and waits for the response.
      It is the same as [snd (call_full m req)].
      This is simpler than using [call_full], but doesn't support pipelining
      (you can't use any capabilities in the response in another message until the
      response arrives).
      Doing [Lwt.cancel] on the result will send a cancel message to the target
      for remote calls. *)

  val call_for_value_exn : 't capability_t -> ('t, 'a, 'b) method_t -> 'a Request.t -> 'b Payload.t Lwt.t
  (** Wrapper for [call_for_value] that turns errors in Lwt failures. *)

  val call_for_caps : 't capability_t -> ('t, 'a, 'b) method_t -> 'a Request.t -> ('b StructRef.t -> 'c) -> 'c
  (** [call_for_caps] is a wrapper for [call] that passes the results to a
      callback and finishes them automatically when it returns.
      In the common case where you want a single cap "foo" from the result, use
      [call_for_caps target meth req R.foo_get_pipelined]. *)

  val inc_ref : _ t -> unit

  val dec_ref : _ t -> unit

  val pp : 'a t Fmt.t
end

module Service : sig
  type ('a, 'b) method_t = 'a Payload.t -> 'b StructRef.t

  module Response : sig
    type 'b t
    (** An ['a t] is a builder for the out-going response's payload. *)

    val create : (Capnp.Message.rw Capnp.BytesMessage.Slice.t -> 'a) -> 'a t * 'a
    (** [create init] is a fresh request payload and contents builder.
        Use one of the generated [init_pointer] functions for [init]. *)

    val create_empty : unit -> 'a t
    (** [empty ()] is an empty response. *)

    val export : 'a t -> 'b Capability.t -> 'b Payload.index
    (** [export t cap] adds [cap] to the payload's CapDescriptor table and returns
        its index. You can use the index with the generated setter.
        The response increases the ref-count of [cap]. It will be released when
        the message is sent. If the message is not sent, you must release it. *)

    val release : 'a t -> unit
    (** Clear the exported refs, dropping their ref-counts. This is called automatically
        when you send a message, but you might need it if you decide to abort. *)
  end

  val return : 'a Response.t -> 'a StructRef.t
  (** [return r] wraps up a simple local result as a promise. *)

  val return_empty : unit -> 'a StructRef.t
  (** [return_empty ()] is a promise for a response with no payload. *)

  val return_lwt : (unit -> 'a Response.t or_error Lwt.t) -> 'a StructRef.t
  (** [return_lwt fn] is a local promise for the result of Lwt thread [fn ()].
      If [fn ()] fails, the error is logged and an "Internal error" returned to the caller.
      Note that this does not support pipelining. *)

  val fail : ?ty:Capnp_rpc.Exception.ty -> ('a, Format.formatter, unit, 'b StructRef.t) format4 -> 'a
  (** [fail msg] is an exception with reason [msg]. *)
end

module Untyped : sig
  (** This module is only for use by the code generated by the capnp-ocaml
      schema compiler. The generated code provides type-safe wrappers for
      everything here. *)

  type pointer_r = Capnp.Message.ro Capnp.BytesMessage.Slice.t option

  val content_of_payload : 'a Payload.t -> pointer_r

  type abstract_method_t

  val abstract_method : ('a, 'b) Service.method_t -> abstract_method_t

  val define_method : interface_id:Uint64.t -> method_id:int ->
    ('t, 'a, 'b) Capability.method_t

  val struct_field : 'a StructRef.t -> int -> 'b StructRef.t

  val capability_field : 'a StructRef.t -> int -> 'b Capability.t

  class type generic_service = object
    method dispatch : interface_id:Uint64.t -> method_id:int -> abstract_method_t
    method release : unit
    method pp : Format.formatter -> unit
  end

  val local : #generic_service -> 'a Capability.t

  val cap_index : Uint32.t option -> _ Payload.index option

  val unknown_interface : interface_id:Uint64.t -> abstract_method_t
  val unknown_method : interface_id:Uint64.t -> method_id:int -> abstract_method_t
end

module CapTP : sig
  type t
  (** A CapTP connection to a remote peer. *)

  val of_endpoint : ?offer:'a Capability.t -> ?tags:Logs.Tag.set -> switch:Lwt_switch.t -> Endpoint.t -> t
  (** [of_endpoint ?offer ~switch endpoint] is fresh CapTP connection wrapping [endpoint].
      If [offer] is given, the peer can use the "Bootstrap" message to get access to it.
      If the connection fails then [switch] will be turned off. *)

  val bootstrap : t -> 'a Capability.t
  (** [bootstrap t] is the peer's public bootstrap object, if any. *)

  val dump : t Fmt.t
  (** [dump] dumps the state of the connection, for debugging. *)
end

module Endpoint = Endpoint
