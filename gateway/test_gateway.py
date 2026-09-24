"""Testes do gateway: validação de entrada e montagem do comando ssh."""
import unittest

import gateway as gw


def req(**over):
    base = {"host_id": 1, "address": "target-alpine", "port": 22,
            "user": "collector", "cert_paths": "/opt/app/certs"}
    base.update(over)
    return base


class Validate(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(gw.validate(req()),
                         (1, "target-alpine", 22, "collector", ["/opt/app/certs"], "modern"))

    def test_perfil_ssh(self):
        self.assertEqual(gw.validate(req(ssh_profile="legacy"))[5], "legacy")
        self.assertEqual(gw.validate(req(ssh_profile=None))[5], "modern")
        for bad in ["LEGACY", "-oProxyCommand=id", "insecure"]:
            with self.assertRaises(gw.BadRequest, msg=bad):
                gw.validate(req(ssh_profile=bad))

    def test_cert_paths_vazio(self):
        self.assertEqual(gw.validate(req(cert_paths=""))[4], [])
        self.assertEqual(gw.validate(req(cert_paths=None))[4], [])

    def test_rejeita_opcao_ssh_disfarcada_de_host(self):
        for bad in ["-oProxyCommand=id", "-v", "host;id", "a b", ""]:
            with self.assertRaises(gw.BadRequest, msg=bad):
                gw.validate(req(address=bad))

    def test_rejeita_injecao_em_path(self):
        for bad in ["/tmp;id", "/tmp/$(id)", "relativo", "/a/../etc", "/tmp`id`"]:
            with self.assertRaises(gw.BadRequest, msg=bad):
                gw.validate(req(cert_paths=bad))

    def test_rejeita_user_e_porta(self):
        with self.assertRaises(gw.BadRequest):
            gw.validate(req(user="root;id"))
        with self.assertRaises(gw.BadRequest):
            gw.validate(req(port=70000))
        with self.assertRaises(gw.BadRequest):
            gw.validate({"address": "x"})


class Command(unittest.TestCase):
    def test_host_depois_de_duplo_hifen(self):
        cmd = gw.build_ssh_cmd("h", 22, "collector", ["/a", "/b c"])
        self.assertEqual(cmd[-3:], ["--", "h", "sh -s -- /a '/b c'"])
        self.assertIn("BatchMode=yes", cmd)

    def test_legado_so_no_host_marcado(self):
        moderno = gw.build_ssh_cmd("h", 22, "collector", [])
        legado = gw.build_ssh_cmd("h", 22, "collector", [], "legacy")
        self.assertNotIn("PubkeyAcceptedAlgorithms=+ssh-rsa", moderno)
        self.assertIn(gw.SSH_KEY, moderno)
        self.assertIn("PubkeyAcceptedAlgorithms=+ssh-rsa", legado)
        self.assertIn("HostKeyAlgorithms=+ssh-rsa", legado)
        self.assertIn(gw.SSH_KEY_LEGACY, legado)
        self.assertEqual(legado[-3:], ["--", "h", "sh -s --"])


class Summary(unittest.TestCase):
    def test_ignora_banner(self):
        err = "@@@@@\n@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\n@@@@@\nfoo\nHost key verification failed."
        self.assertEqual(gw.summarize(err, 255), "Host key verification failed.")

    def test_sem_stderr(self):
        self.assertIn("exit 0", gw.summarize("", 0))


if __name__ == "__main__":
    unittest.main()
