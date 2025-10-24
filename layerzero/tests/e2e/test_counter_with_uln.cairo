//! E2E test for Counter with UltraLightNode302 (ULN + DVN + Executor)

use alexandria_bytes::byte_array_ext::ByteArrayTraitExt;
use core::num::traits::Bounded;
use layerzero::common::guid::GUID;
use layerzero::common::packet_v1_codec::PacketV1Codec;
use layerzero::common::structs::packet::Origin;
use layerzero::message_lib::interface::IMessageLibDispatcherTrait;
use layerzero::message_lib::uln_302;
use layerzero::message_lib::uln_302::options::TYPE_3;
use layerzero::message_lib::uln_302::structs::executor_config::ExecutorConfig;
use layerzero::message_lib::uln_302::structs::uln_config::UlnConfig;
use layerzero::oapps::counter::constants::INCREMENT_TYPE_A_B;
use layerzero::oapps::counter::counter::OmniCounter;
use layerzero::oapps::counter::interface::IOmniCounterDispatcherTrait;
use layerzero::oapps::counter::structs::{IncrementReceived, IncrementSent};
use layerzero::oapps::oapp::interface::IOAppDispatcherTrait;
use layerzero::treasury::interfaces::treasury_admin::ITreasuryAdminDispatcherTrait;
use layerzero::workers::base::interface::IWorkerBaseDispatcherTrait;
use layerzero::workers::dvn::interface::IDvnDispatcherTrait;
use layerzero::workers::dvn::structs::ExecuteParam as DvnExecuteParam;
use layerzero::workers::executor::interface::IExecutorDispatcherTrait;
use layerzero::workers::executor::options::OPTION_TYPE_LZRECEIVE;
use layerzero::workers::executor::structs::ExecuteParams;
use lz_utils::bytes::ContractAddressIntoBytes32;
use openzeppelin::token::erc20::interface::IERC20DispatcherTrait;
use snforge_std::{EventSpyAssertionsTrait, EventSpyTrait, EventsFilterTrait, spy_events};
use starknet::ContractAddress;
use starknet::account::Call;
use starkware_utils_testing::test_utils::cheat_caller_address_once;
use utils::{
    BlockchainOptions, DEFAULT_DVN_DST_CONFIG, DEFAULT_EXECUTOR_DST_CONFIG, DvnHelper,
    EndpointV2Helper, ExecutorHelper, OmniCounterHelper, TreasuryHelper, UltraLightNode302Helper,
    decode_executor_options, decode_packet_on_endpoint, deploy_omni_counter, setup_layer_zero,
    wire_oapp, wire_ultra_light_node_302,
};
use crate::constants::assert_eq;
use crate::e2e::utils;
use crate::e2e::utils::ERC20Helper;
use crate::fuzzable::blockchain_config::BlockchainConfig;
use crate::fuzzable::contract_address::FuzzableContractAddress;
use crate::fuzzable::eid::FuzzableEid;
use crate::fuzzable::keys::FuzzableKeyPair;
use crate::mocks::erc20::interface::IMockERC20DispatcherTrait;
use crate::workers::dvn::utils::build_signatures;
use crate::workers::executor::utils::{
    ExecutorOptionBytes, serialize_executor_options, serialize_lz_receive_option,
};

const DVN_CONFIRMATIONS: u64 = 1;
const MAX_MESSAGE_SIZE: u32 = 1024;
const LZ_RECEIVE_USER_GAS: u128 = 100_000;
const TREASURY_NATIVE_FEE_CAP: u256 = 0;

#[derive(Drop)]
struct Blockchain {
    native_token: ERC20Helper,
    endpoint: EndpointV2Helper,
    message_lib: UltraLightNode302Helper,
    treasury: TreasuryHelper,
    executor: ExecutorHelper,
    dvn: DvnHelper,
    counter: OmniCounterHelper,
}

fn setup_blockchain(config: @BlockchainConfig, remote_eid: u32) -> Blockchain {
    let chain = setup_layer_zero(
        config,
        BlockchainOptions {
            dvn_dst_config: DEFAULT_DVN_DST_CONFIG,
            treasury_native_fee_cap: TREASURY_NATIVE_FEE_CAP,
        },
        remote_eid,
    );

    let counter = deploy_omni_counter(
        chain.endpoint.address, *config.oapp_owner, chain.native_token.address,
    );
    cheat_caller_address_once(counter.address, *config.oapp_owner);
    counter.oapp.set_delegate(*config.oapp_owner);

    Blockchain {
        native_token: chain.native_token,
        endpoint: chain.endpoint,
        message_lib: chain.message_lib,
        treasury: chain.treasury,
        executor: chain.executor,
        dvn: chain.dvn,
        counter,
    }
}

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

fn create_message_options() -> ByteArray {
    let executor_options = serialize_executor_options(
        array![
            ExecutorOptionBytes {
                option_type: OPTION_TYPE_LZRECEIVE,
                option: serialize_lz_receive_option(LZ_RECEIVE_USER_GAS, None),
            },
        ],
    );

    let mut options: ByteArray = Default::default();
    options.append_u16(TYPE_3);
    options.append(@executor_options);
    options
}

#[test]
#[fuzzer(runs: 10)]
fn test_send_and_receive(src_config: BlockchainConfig, dst_config: BlockchainConfig) {
    let src = setup_blockchain(@src_config, dst_config.eid.eid);
    let dst = setup_blockchain(@dst_config, src_config.eid.eid);

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
        src.counter.oapp,
        src_config.oapp_owner,
        dst_config.eid.eid,
        dst.counter.address,
    );

    wire_oapp(
        @dst.endpoint,
        dst.message_lib.address,
        dst.counter.oapp,
        dst_config.oapp_owner,
        src_config.eid.eid,
        src.counter.address,
    );

    // =============================== Send a message =================================

    let options = create_message_options();
    let fee = src
        .counter
        .omni_counter
        .quote(dst_config.eid.eid, INCREMENT_TYPE_A_B, options.clone(), false);

    assert_gt!(fee.native_fee, 0);
    assert_eq(fee.lz_token_fee, 0);

    cheat_caller_address_once(src.native_token.address, src_config.native_token_owner);
    src.native_token.mock_erc20.mint(src_config.user, fee.native_fee);

    assert_eq(src.native_token.erc20.balance_of(src_config.user), fee.native_fee);

    cheat_caller_address_once(src.native_token.address, src_config.user);
    src.native_token.erc20.approve(src.counter.address, fee.native_fee);

    let mut spy = spy_events();

    cheat_caller_address_once(src.counter.address, src_config.user);
    src
        .counter
        .omni_counter
        .increment(dst_config.eid.eid, INCREMENT_TYPE_A_B, options, fee.clone(), src_config.user);

    assert_eq(src.native_token.erc20.balance_of(src_config.user), 0);

    spy
        .assert_emitted(
            @array![
                (
                    src.counter.address,
                    OmniCounter::Event::IncrementSent(
                        IncrementSent {
                            sender: src_config.user,
                            dst_eid: dst_config.eid.eid,
                            increment_type: INCREMENT_TYPE_A_B,
                        },
                    ),
                ),
            ],
        );

    cheat_caller_address_once(src.dvn.address, src_config.dvn_admin);
    src
        .dvn
        .worker_base
        .withdraw_fee(
            src.native_token.address,
            src_config.dvn_owner,
            src.native_token.erc20.balance_of(src.dvn.address),
        );

    assert_gt!(src.native_token.erc20.balance_of(src_config.dvn_owner), 0);

    cheat_caller_address_once(src.executor.address, src_config.executor_admin);
    src
        .executor
        .worker_base
        .withdraw_fee(
            src.native_token.address,
            src_config.executor_role_admin,
            src.native_token.erc20.balance_of(src.executor.address),
        );

    assert_gt!(src.native_token.erc20.balance_of(src_config.executor_role_admin), 0);

    cheat_caller_address_once(src.treasury.address, src_config.treasury_owner);
    src
        .treasury
        .treasury_admin
        .withdraw_tokens(
            src.native_token.address,
            src_config.treasury_owner,
            src.native_token.erc20.balance_of(src.treasury.address),
        );

    assert_eq(src.native_token.erc20.balance_of(src_config.treasury_owner), fee.native_fee / 2);

    // =============================== DVN emulation =================================

    let events = spy.get_events().emitted_by(src.endpoint.address).events;

    assert_eq(events.len(), 1);

    let (_, event) = events.at(0);
    let (encoded_packet, options) = decode_packet_on_endpoint(event);
    let packet = PacketV1Codec::decode(@encoded_packet);
    let (executor_options, _) = uln_302::options::split_options(@options);

    assert_eq(packet.nonce, 1);
    assert_eq(packet.src_eid, src_config.eid.eid);
    assert_eq(packet.sender, src.counter.address);
    assert_eq(packet.dst_eid, dst_config.eid.eid);
    assert_eq(packet.receiver, dst.counter.address.into());
    assert_eq(
        packet.guid,
        GUID::generate(
            packet.nonce,
            packet.src_eid,
            packet.sender.into(),
            packet.dst_eid.into(),
            packet.receiver.into(),
        ),
    );
    assert_eq(
        packet.message.clone(),
        {
            let mut message: ByteArray = Default::default();
            message.append_u8(INCREMENT_TYPE_A_B);
            message
        },
    );

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

    // =============================== Receive a message =================================

    dst
        .message_lib
        .message_lib
        .commit(
            PacketV1Codec::header(@encoded_packet), PacketV1Codec::payload_hash(@encoded_packet),
        );

    let executor_options = decode_executor_options(@executor_options);

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

    assert_eq(dst.counter.omni_counter.get_counter(src_config.eid.eid), 1);

    spy
        .assert_emitted(
            @array![
                (
                    dst.counter.address,
                    OmniCounter::Event::IncrementReceived(
                        IncrementReceived {
                            src_eid: src_config.eid.eid,
                            old_value: 0,
                            new_value: 1,
                            increment_type: INCREMENT_TYPE_A_B,
                            value: 0,
                        },
                    ),
                ),
            ],
        );
}
