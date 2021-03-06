#
#    Copyright 2020, NTT Communications Corp.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

import logging
from web3 import Web3
from contract_visitor import ContractVisitor

LOGGER = logging.getLogger('common')


class CTIToken(ContractVisitor):

    contract_interface = dict()
    pool = dict()

    def __init__(self):
        super().__init__()
        self.contract_id = 'CTIToken.sol:CTIToken'

    def balance_of(self, account_id):
        func = self.contract.functions.balanceOf(account_id)
        return func.call()

    def send_token(self, dest, amount=1, data=''):
        bdata = Web3.toBytes(text=data)
        func = self.contract.functions.send(dest, amount, bdata)
        tx_hash = func.transact()
        tx_receipt = self.contracts.web3.eth.waitForTransactionReceipt(tx_hash)
        self.gaslog('send', tx_receipt)
        if tx_receipt['status'] != 1:
            raise ValueError('Transaction failed: send')

    def burn_token(self, amount, data=''):
        func = self.contract.functions.burn(amount, data)
        tx_hash = func.transact()
        tx_receipt = self.contracts.web3.eth.waitForTransactionReceipt(tx_hash)
        self.gaslog('burn', tx_receipt)
        if tx_receipt['status'] != 1:
            raise ValueError('Transaction failed: burn')

    def authorize_operator(self, operator):
        func = self.contract.functions.authorizeOperator(operator)
        tx_hash = func.transact()
        tx_receipt = self.contracts.web3.eth.waitForTransactionReceipt(tx_hash)
        self.gaslog('authorizeOperator', tx_receipt)
        if tx_receipt['status'] != 1:
            raise ValueError('Transaction failed: authorizeOperator')

    def revoke_operator(self, operator):
        func = self.contract.functions.revokeOperator(operator)
        tx_hash = func.transact()
        tx_receipt = self.contracts.web3.eth.waitForTransactionReceipt(tx_hash)
        self.gaslog('revokeOperator', tx_receipt)
        if tx_receipt['status'] != 1:
            raise ValueError('Transaction failed: revokeOperator')
