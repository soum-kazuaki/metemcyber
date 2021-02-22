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
import socket
from threading import Thread
from socketserver import TCPServer
from http.server import SimpleHTTPRequestHandler
from web3 import Web3
from solver import BaseSolver
from client_model import FILESERVER_ASSETS_PATH

LOGGER = logging.getLogger('common')

JOIN_TIMEOUT_SEC = 30
LISTEN_ADDR = ''
LISTEN_PORT = 50080
LISTEN_PORT_RANGE = 1000
CONTENTS_ROOT = FILESERVER_ASSETS_PATH


class SimpleHandler(SimpleHTTPRequestHandler):

    def __init__(self, *args):
        self.logpref = 'LocalHttpServer'
        SimpleHTTPRequestHandler.__init__(self, *args, directory=CONTENTS_ROOT)

    def do_GET(self):
        SimpleHTTPRequestHandler.do_GET(self)

    def log_error(self, *args):
        LOGGER.error(self.logpref+': '+args[0], *args[1:])

    def log_message(self, *args):
        LOGGER.info(self.logpref+': '+args[0], *args[1:])


class LocalHttpServer():

    def __init__(self, identity):
        self.identity = identity
        self.thread = None
        self.server = None
        self.addr = LISTEN_ADDR
        self.port = 0
        self.handler = SimpleHandler

    def start(self):
        if self.thread:
            return
        self.thread = Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        for self.port in range(LISTEN_PORT, LISTEN_PORT+LISTEN_PORT_RANGE+1):
            try:
                LOGGER.info(
                    '%s: starting httpd: %s at %s:%d',
                    self.__class__.__name__, self.identity,
                    self.addr, self.port)
                with TCPServer((self.addr, self.port), self.handler) as httpd:
                    self.server = httpd
                    httpd.serve_forever()
                LOGGER.info(
                    '%s: stopped httpd: %s',
                    self.__class__.__name__, self.identity)
                return
            except OSError as err:
                if err.errno == 98:  # EADDRINUSE (address already in use)
                    continue
                raise
        raise Exception("cannot assign listen port for httpd")

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server = None
        if self.thread:
            self.thread.join(timeout=JOIN_TIMEOUT_SEC)
            if self.thread.is_alive():
                LOGGER.error('failed stopping httpd: %s', self.identity)
            self.thread = None


class Solver(BaseSolver):

    def __init__(self, contracts, account_id, operator_address):
        super().__init__(contracts, account_id, operator_address)
        self.fileserver = LocalHttpServer(operator_address)
        self.fileserver.start()

    def destroy(self):
        super().destroy()
        if self.fileserver:
            self.fileserver.stop()
            self.fileserver = None

    def process_challenge(self, token_address, event):
        LOGGER.info('StandaloneSolver: callback: %s', token_address)
        LOGGER.debug(event)

        task_id = event['args']['taskId']
        challenge_seeker = event['args']['from']
        LOGGER.info(
            'accepting task %s from seeker %s', task_id, challenge_seeker)
        if not self.accept_task(task_id):
            LOGGER.warning('could not accept task %s', task_id)
            return

        LOGGER.info('accepted task %s', task_id)
        data = ''
        try:
            # process for Demo
            download_url = self.create_misp_download_url(
                self.account_id, token_address)
            url = Web3.toText(event['args']['data'])

            # return answer via webhook
            LOGGER.info('returning answer to %s', url)
            self.webhook(url, download_url, token_address)
        except Exception as err:
            data = str(err)
            LOGGER.exception(err)
            LOGGER.error('failed task %s', task_id)
        finally:
            self.finish_task(task_id, data)
            LOGGER.info('finished task %s', task_id)

    def create_misp_download_url(self, _account_id, cti_address):
        url = 'http://{host}:{port}/{path}'.format(
            host=socket.gethostname(),
            port=self.fileserver.port,
            path=cti_address)
        return url
