//! E2E test to send a LZ compose message on a OFT transfer with ULN

use alexandria_bytes::byte_array_ext::ByteArrayTraitExt;
use core::num::traits::Bounded;
use core::panic_with_felt252;
use endpoint::endpoint_v2::EndpointV2;
use endpoint::messaging_composer::events::ComposeSent;
use endpoint::messaging_composer::messaging_composer::MessagingComposerComponent;
use layerzero::common::packet_v1_codec::PacketV1Codec;
use layerzero::common::structs::packet::Origin;
use layerzero::endpoint;
use layerzero::message_lib::interface::IMessageLibDispatcherTrait;
use layerzero::message_lib::uln_302;
use layerzero::message_lib::uln_302::options::TYPE_3;
use layerzero::message_lib::uln_302::structs::executor_config::ExecutorConfig;
use layerzero::message_lib::uln_302::structs::uln_config::UlnConfig;
use layerzero::oapps::oft::interface::IOFTDispatcherTrait;
use layerzero::oapps::oft::structs::SendParam;
use layerzero::treasury::interfaces::treasury_admin::ITreasuryAdminDispatcherTrait;
use layerzero::workers::base::interface::IWorkerBaseDispatcherTrait;
use layerzero::workers::dvn::interface::IDvnDispatcherTrait;
use layerzero::workers::dvn::structs::ExecuteParam as DvnExecuteParam;
use layerzero::workers::executor::interface::IExecutorDispatcherTrait;
use layerzero::workers::executor::options::{OPTION_TYPE_LZCOMPOSE, OPTION_TYPE_LZRECEIVE};
use layerzero::workers::executor::structs::{ComposeParams, ExecuteParams};
use lz_utils::bytes::ContractAddressIntoBytes32;
use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
use snforge_std::cheatcodes::events::Events;
use snforge_std::{EventSpyTrait, EventsFilterTrait, spy_events};
use starknet::ContractAddress;
use starknet::account::Call;
use starkware_utils_testing::test_utils::cheat_caller_address_once;
use crate::constants::assert_eq;
use crate::e2e::oft_utils::{DIFF_DECIMALS, mint_tokens};
use crate::e2e::utils::{
    DEFAULT_EXECUTOR_DST_CONFIG, decode_executor_options, decode_packet_on_endpoint,
    deploy_mock_composer_target, wire_ultra_light_node_302,
};
use crate::fuzzable::blockchain_config::BlockchainConfig;
use crate::fuzzable::contract_address::FuzzableContractAddress;
use crate::fuzzable::eid::FuzzableEid;
use crate::fuzzable::keys::FuzzableKeyPair;
use crate::mocks::composer_target::MockComposerTarget::IMockComposerTargetInspectDispatcherTrait;
use crate::mocks::erc20::interface::IMockERC20DispatcherTrait;
use crate::workers::dvn::utils::build_signatures;
use crate::workers::executor::utils::{
    ExecutorOptionBytes, serialize_executor_options, serialize_lz_compose_option,
    serialize_lz_receive_option,
};
use super::oft_utils::setup_blockchain;
use super::utils::wire_oapp;

const DVN_CONFIRMATIONS: u64 = 1;
const MAX_MESSAGE_SIZE: u32 = 1024;
const MAX_COMPOSE_MESSAGE_SIZE: u32 = MAX_MESSAGE_SIZE * 9 / 10;

fn create_uln_config(confirmations: u64, dvn: ContractAddress) -> UlnConfig {
    UlnConfig {
        confirmations,
        has_confirmations: true,
        required_dvns: array![dvn],
        has_required_dvns: true,
        optional_dvns: array![],
        optional_dvn_threshold: 0,
        has_optional_dvns: true,
    }
}

fn create_message_options(compose_value: u128) -> ByteArray {
    let executor_options = serialize_executor_options(
        array![
            ExecutorOptionBytes {
                option_type: OPTION_TYPE_LZRECEIVE,
                option: serialize_lz_receive_option(100_000, None),
            },
            ExecutorOptionBytes {
                option_type: OPTION_TYPE_LZCOMPOSE,
                option: serialize_lz_compose_option(0, 100_000, Some(compose_value)),
            },
        ],
    );

    let mut options: ByteArray = Default::default();
    options.append_u16(TYPE_3);
    options.append(@executor_options);
    options
}

fn decode_compose_on_endpoint(events: Events) -> ComposeSent {
    for (_, event) in events.events {
        let mut keys = event.keys.span();
        let mut data = event.data.span();
        let event: EndpointV2::Event = starknet::Event::deserialize(ref keys, ref data)
            .expect('endpoint event');

        if let EndpointV2::Event::MessagingComposerEvent(MessagingComposerComponent::Event::ComposeSent(event)) =
            event {
            return event;
        }
    }

    panic_with_felt252('no compose event on endpoint')
}

#[test]
#[fuzzer(runs: 10)]
fn test_transfer_tokens(
    src_config: BlockchainConfig,
    dst_config: BlockchainConfig,
    amount_seed: u256,
    compose_msg: ByteArray,
    compose_msg_last_byte: u8,
    compose_value: u32,
) {
    let src = setup_blockchain(@src_config, dst_config.eid.eid);
    let dst = setup_blockchain(@dst_config, src_config.eid.eid);

    let composer_target = deploy_mock_composer_target();

    // =============================== Transfer parameters =================================

    let amount_ld = amount_seed % (Bounded::<u64>::MAX.into() * DIFF_DECIMALS);
    let amount_sd: u64 = (amount_ld / DIFF_DECIMALS).try_into().unwrap();
    let dust_ld = amount_ld % DIFF_DECIMALS;
    let clean_amount_ld = amount_ld - dust_ld;
    // Expect a lossless token transfer.
    let min_amount_ld = amount_sd.into() * DIFF_DECIMALS;

    // Preconditions
    assert_eq(clean_amount_ld, min_amount_ld);
    assert(amount_sd > 0, 'Greater than 0'); // Hopefully, we never hit 0 of `u64`...

    let compose_msg = compose_msg
        .into_iter()
        .take(MAX_COMPOSE_MESSAGE_SIZE - 1)
        .chain(Some(compose_msg_last_byte))
        .collect();

    // =============================== Wiring =================================

    wire_ultra_light_node_302(
        src_config.message_lib_owner,
        @src.message_lib,
        dst_config.eid.eid,
        create_uln_config(DVN_CONFIRMATIONS, src.dvn.address),
        ExecutorConfig { executor: src.executor.address, max_message_size: MAX_MESSAGE_SIZE },
    );

    wire_ultra_light_node_302(
        dst_config.message_lib_owner,
        @dst.message_lib,
        src_config.eid.eid,
        create_uln_config(DVN_CONFIRMATIONS, dst.dvn.address),
        ExecutorConfig { executor: dst.executor.address, max_message_size: MAX_MESSAGE_SIZE },
    );

    wire_oapp(
        @src.endpoint,
        src.message_lib.address,
        src.oft.oapp,
        src_config.oapp_owner,
        dst_config.eid.eid,
        dst.oft.address,
    );

    wire_oapp(
        @dst.endpoint,
        dst.message_lib.address,
        dst.oft.oapp,
        dst_config.oapp_owner,
        src_config.eid.eid,
        src.oft.address,
    );

    // =============================== Send tokens =================================

    const REMAINDER_SD: u64 = 1;
    let balance_sd = amount_sd + REMAINDER_SD;
    mint_tokens(
        src.oft.address,
        src_config.user,
        balance_sd,
        src.endpoint.address,
        Origin { src_eid: dst_config.eid.eid, sender: dst.oft.address.into(), nonce: 1 },
    );

    assert_eq(src.oft.erc20.balance_of(src_config.user), balance_sd.into() * DIFF_DECIMALS);

    let send_param = SendParam {
        dst_eid: dst_config.eid.eid,
        to: composer_target.address.into(),
        amount_ld,
        min_amount_ld,
        extra_options: create_message_options(compose_value.into()),
        compose_msg: compose_msg.clone(),
        oft_cmd: "",
    };
    let quote = src.oft.oft.quote_oft(send_param.clone());

    assert_eq(quote.receipt.amount_sent_ld, clean_amount_ld);
    assert_eq(quote.receipt.amount_received_ld, clean_amount_ld);
    assert_eq(quote.limit.min_amount_ld, 0);
    assert_eq(quote.limit.max_amount_ld, src.oft.erc20.total_supply());
    assert_eq(quote.oft_fee_details.len(), 0);

    let fee = src.oft.oft.quote_send(send_param.clone(), false);

    assert(fee.native_fee > 0, 'Greater than 0');
    assert_eq(fee.lz_token_fee, 0);

    cheat_caller_address_once(src.native_token.address, src_config.native_token_owner);
    src.native_token.mock_erc20.mint(src_config.user, fee.native_fee);

    assert_eq(src.native_token.erc20.balance_of(src_config.user), fee.native_fee);

    cheat_caller_address_once(src.native_token.address, src_config.user);
    src.native_token.erc20.approve(src.oft.address, fee.native_fee);

    let mut spy = spy_events();

    cheat_caller_address_once(src.oft.address, src_config.user);
    let result = src.oft.oft.send(send_param, fee.clone(), src_config.user);

    assert_eq(result.oft_receipt.amount_sent_ld, clean_amount_ld);
    assert_eq(result.oft_receipt.amount_received_ld, clean_amount_ld);
    assert_eq(src.native_token.erc20.balance_of(src_config.user), 0);
    assert_eq(src.oft.erc20.balance_of(src_config.user), REMAINDER_SD.into() * DIFF_DECIMALS);

    cheat_caller_address_once(src.dvn.address, src_config.dvn_admin);
    src
        .dvn
        .worker_base
        .withdraw_fee(
            src.native_token.address,
            src_config.dvn_owner,
            src.native_token.erc20.balance_of(src.dvn.address),
        );

    assert(src.native_token.erc20.balance_of(src_config.dvn_owner) > 0, 'Greater than 0');

    cheat_caller_address_once(src.executor.address, src_config.executor_admin);
    src
        .executor
        .worker_base
        .withdraw_fee(
            src.native_token.address,
            src_config.executor_role_admin,
            src.native_token.erc20.balance_of(src.executor.address),
        );

    assert(src.native_token.erc20.balance_of(src_config.executor_role_admin) > 0, 'Greater than 0');

    cheat_caller_address_once(src.treasury.address, src_config.treasury_owner);
    src
        .treasury
        .treasury_admin
        .withdraw_tokens(
            src.native_token.address,
            src_config.message_lib_owner,
            src.native_token.erc20.balance_of(src.treasury.address),
        );

    assert_eq(src.native_token.erc20.balance_of(src_config.message_lib_owner), fee.native_fee / 2);

    // =============================== DVN emulation =================================

    let events = spy.get_events().emitted_by(src.endpoint.address).events;

    assert_eq(events.len(), 1);

    let (_, event) = events.at(0);
    let (encoded_packet, options) = decode_packet_on_endpoint(event);
    let packet = PacketV1Codec::decode(@encoded_packet);
    let (executor_options, _) = uln_302::options::split_options(@options);

    let mut calldata = array![];
    PacketV1Codec::header(@encoded_packet).serialize(ref calldata);
    PacketV1Codec::payload_hash(@encoded_packet).serialize(ref calldata);
    DVN_CONFIRMATIONS.serialize(ref calldata);

    let call_data = Call {
        to: dst.message_lib.address, selector: selector!("verify"), calldata: calldata.span(),
    };
    let expiration = Bounded::<u256>::MAX;
    let hash = dst.dvn.dvn.hash_call_data(dst_config.dvn_vid, call_data, expiration);
    let signatures = build_signatures(
        array![dst_config.dvn_signers[0].clone(), dst_config.dvn_signers[1].clone()].span(), hash,
    );

    cheat_caller_address_once(dst.dvn.address, dst_config.dvn_admin);
    dst
        .dvn
        .dvn
        .execute(
            array![
                DvnExecuteParam {
                    vid: dst_config.dvn_vid, call_data, expiration, signatures: signatures.span(),
                },
            ],
        );

    // =============================== Receive tokens =================================

    dst
        .message_lib
        .message_lib
        .commit(
            PacketV1Codec::header(@encoded_packet), PacketV1Codec::payload_hash(@encoded_packet),
        );

    let executor_options = decode_executor_options(@executor_options);

    assert_eq(dst.native_token.erc20.balance_of(composer_target.address), 0);
    assert_eq(dst.oft.erc20.balance_of(composer_target.address), 0);

    cheat_caller_address_once(dst.executor.address, dst_config.executor_admin);
    dst
        .executor
        .executor
        .execute(
            ExecuteParams {
                receiver: packet.receiver.try_into().unwrap(),
                origin: Origin {
                    src_eid: packet.src_eid, sender: packet.sender.into(), nonce: packet.nonce,
                },
                guid: packet.guid,
                message: packet.message,
                gas_limit: (*executor_options.receive.gas).into()
                    + DEFAULT_EXECUTOR_DST_CONFIG.lz_receive_base_gas.into(),
                value: (*executor_options.receive.value).into(),
                extra_data: "",
            },
        );

    assert_eq(dst.native_token.erc20.balance_of(composer_target.address), 0);
    assert_eq(dst.oft.erc20.balance_of(composer_target.address), clean_amount_ld);

    // =============================== Compose =================================

    let event = decode_compose_on_endpoint(spy.get_events().emitted_by(dst.endpoint.address));
    let mut compose_options = executor_options.compose.span().into_iter();
    let compose_option = *compose_options.find(|option| ***option.index == event.index).unwrap();

    cheat_caller_address_once(dst.native_token.address, dst_config.native_token_owner);
    dst.native_token.mock_erc20.mint(dst.executor.address, (*compose_option.value).into());

    cheat_caller_address_once(dst.executor.address, dst_config.executor_admin);
    dst
        .executor
        .executor
        .compose(
            ComposeParams {
                sender: event.from,
                receiver: event.to,
                guid: event.guid,
                message: event.message,
                index: event.index,
                gas_limit: (*compose_option.gas).into()
                    + DEFAULT_EXECUTOR_DST_CONFIG.lz_compose_base_gas.into(),
                value: (*compose_option.value).into(),
                extra_data: "",
            },
        );

    assert_eq(composer_target.composer_target_inspect.received_count(), 1);
    assert_eq(composer_target.composer_target_inspect.last_from(), event.from);
    assert_eq(composer_target.composer_target_inspect.last_guid(), event.guid);
    assert_eq(composer_target.composer_target_inspect.last_message(), compose_msg);
    assert_eq(composer_target.composer_target_inspect.last_value(), compose_value.into());
    assert_eq(dst.native_token.erc20.balance_of(composer_target.address), compose_value.into());
}
