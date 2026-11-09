from pathlib import Path
import json
import tempfile
import unittest
import zipfile

import backend as b
import meeting_documents as d
import archive_runner as runner
import test_backend as local_fixture
import test_openai_pipeline as openai_fixture
import test_plaud_account as plaud_fixture


def attach(folder):
    source=folder.parent/'附加说明.md'; source.write_text('# 计划\n今天不发布。Keep English as spoken.\n')
    row=d.prepare(source,folder); m=b.read(folder/'meeting.json'); m['documents']=[row]; b.atomic(folder/'meeting.json',m)
    return row


def attach_link(folder):
    row=d.prepare_link('https://docs.example.invalid/会议计划?version=2#预算',folder,'会议计划')
    m=b.read(folder/'meeting.json');m['documents']=[row];b.atomic(folder/'meeting.json',m)
    return row


def check_package(test, receipt, row, vault):
    raw=Path(receipt['raw_dir']); manifest=b.read(raw/'manifest.json')
    test.assertEqual(manifest['documents'],[row]);test.assertEqual(b.digest(raw/row['path']),row['sha256'])
    if row.get('text_path'): test.assertEqual(b.digest(raw/row['text_path']),row['text_sha256'])
    test.assertEqual(manifest['sha256'][row['path']],row['sha256'])
    test.assertEqual(b.read(raw/'context.json')['documents'],[row])
    job=b.read(receipt['job_path']); job['file_id']=receipt['file_id']
    original,hashes=runner.evidence(job,vault);runner.verify_originals(original,hashes)
    b.atomic(raw/row['path'],'tampered')
    with test.assertRaises(ValueError): runner.verify_originals(original,hashes)


class DocumentExtractionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.dest=self.root/'meeting';self.dest.mkdir()
    def tearDown(self):self.tmp.cleanup()
    def test_utf8_and_duplicate_import_preserve_source(self):
        p=self.root/'原文.md';p.write_text('今天不发布。Do not ship today.'); before=p.read_bytes()
        first=d.prepare(p,self.dest);second=d.prepare(p,self.dest)
        self.assertEqual(first,second);self.assertEqual(p.read_bytes(),before)
        self.assertEqual((self.dest/first['text_path']).read_text(),'今天不发布。Do not ship today.')
        with self.assertRaises(ValueError):d.validate(self.dest,[first,second])
    def test_passive_office_extraction_preserves_tables_slides_and_cells(self):
        fixtures={
          'docx':{'word/document.xml':'<document><p><t>不要发布</t></p><tbl><tr><tc><p><t>API pilot</t></p></tc></tr></tbl></document>'},
          'pptx':{'ppt/presentation.xml':'<presentation/>','ppt/slides/slide1.xml':'<slide><p><t>今天不发布</t></p></slide>'},
          'xlsx':{'xl/workbook.xml':'<workbook/>','xl/sharedStrings.xml':'<sst><si><t>预算</t></si></sst>','xl/worksheets/sheet1.xml':'<sheet><row><c r="A1" t="s"><v>0</v></c><c r="B1"><f>250*2</f><v>500</v></c></row></sheet>'}}
        for ext,files in fixtures.items():
            p=self.root/('sample.'+ext)
            with zipfile.ZipFile(p,'w') as z:
                for name,txt in files.items():z.writestr(name,txt)
            row=d.prepare(p,self.dest);self.assertEqual(row['extraction_status'],'ready')
            text=(self.dest/row['text_path']).read_text()
            self.assertIn('预算' if ext=='xlsx' else '发布',text)
            if ext=='xlsx':self.assertIn('B1: 500 [公式: 250*2',text)
    def test_missing_tampered_and_traversal_never_package(self):
        p=self.root/'a.txt';p.write_text('source');row=d.prepare(p,self.dest)
        for bad in [dict(row,path='../a.txt'),dict(row,sha256='0'*64),dict(row,text_sha256='0'*64)]:
            with self.assertRaises(ValueError):d.package(self.dest,[bad],[self.root/'raw'])
        self.assertFalse((self.root/'raw').exists())
    def test_unsupported_and_oversize_fail_without_upload(self):
        p=self.root/'run.sh';p.write_text('echo no')
        with self.assertRaises(ValueError):d.prepare(p,self.dest)
        p=self.root/'huge.txt'
        with p.open('wb') as f:f.truncate(d.MAX_FILE+1)
        with self.assertRaises(ValueError):d.prepare(p,self.dest)
    def test_unreadable_and_long_content_explicitly_marked(self):
        p=self.root/'bad.docx';p.write_text('not a ZIP');row=d.prepare(p,self.dest)
        self.assertEqual(row['extraction_status'],'original_only');self.assertNotIn('text_path',row)
        p=self.root/'long.md';p.write_text('中'*(d.MAX_TEXT+20));row=d.prepare(p,self.dest)
        self.assertEqual(row['extraction_status'],'partial');self.assertEqual(len((self.dest/row['text_path']).read_text()),d.MAX_TEXT)
    def test_link_reference_is_not_downloaded_content_and_preserves_target(self):
        row=d.prepare_link(' HTTPS://Docs.Example.invalid/Path?token=AbC#section=2 ',self.dest,'预算计划')
        self.assertEqual(row['source_url'],'https://docs.example.invalid/Path?token=AbC#section=2')
        self.assertEqual(row['extraction_status'],'link_pending');self.assertNotIn('text_path',row)
        payload=json.loads((self.dest/row['path']).read_text())
        self.assertEqual(payload,dict(type='document_link',name='预算计划',url=row['source_url']))
        self.assertEqual(d.validate(self.dest,[row]),[row])
    def test_links_reject_unsafe_schemes_credentials_and_malformed_input(self):
        for value in ['file:///etc/passwd','javascript:alert(1)','data:text/plain,test','/tmp/doc.pdf','https://user:pass@example.com/a','https://example.com:invalid/x','https://example.com/a\nb','https://example.com\\@other/a','hello','https://']:
            with self.subTest(value=value),self.assertRaises(ValueError):d.prepare_link(value,self.dest)
    def test_link_metadata_cannot_override_sealed_reference_or_claim_read(self):
        row=d.prepare_link('https://example.invalid/a',self.dest)
        for bad in [dict(row,source_url='https://example.invalid/b'),dict(row,name='changed'),dict(row,extraction_status='ready')]:
            with self.assertRaises(ValueError):d.validate(self.dest,[bad])
        duplicate=d.prepare_link(row['source_url'],self.dest,'different name')
        with self.assertRaises(ValueError):d.validate(self.dest,[row,duplicate])
        b.atomic(self.dest/row['path'],'changed')
        with self.assertRaises(ValueError):d.validate(self.dest,[row])
    def test_link_and_local_document_share_count_limit(self):
        source=self.root/'source.txt';source.write_text('Actual content')
        file=d.prepare(source,self.dest)
        links=[d.prepare_link('https://example.invalid/'+str(i),self.dest) for i in range(10)]
        self.assertEqual(len(d.validate(self.dest,[file]+links[:9])),10)
        with self.assertRaises(ValueError):d.validate(self.dest,[file]+links)


class LocalDocumentHandoff(unittest.TestCase):
    setUp=local_fixture.HandoffTests.setUp
    tearDown=local_fixture.HandoffTests.tearDown
    def test_link_reaches_same_local_archive_and_cannot_change_on_retry(self):
        row=attach_link(self.dir);receipt=b.submit(self.dir,self.vault)
        self.assertEqual(b.submit(self.dir,self.vault),receipt)
        q=local_fixture.bridge.Bridge(self.vault,self.root/'runtime',self.root/'missing.json');q.claim(self.id)
        self.assertEqual(len(q.jobs()),1);check_package(self,receipt,row,self.vault)
    def test_documents_reach_existing_job_once_and_are_immutable(self):
        row=attach(self.dir);receipt=b.submit(self.dir,self.vault)
        self.assertEqual(b.submit(self.dir,self.vault),receipt)
        q=local_fixture.bridge.Bridge(self.vault,self.root/'runtime',self.root/'missing.json');q.claim(self.id)
        self.assertEqual(len(q.jobs()),1);check_package(self,receipt,row,self.vault)
    def test_finish_requires_actual_attachment_review_record(self):
        attach(self.dir);receipt=b.submit(self.dir,self.vault)
        q=local_fixture.bridge.Bridge(self.vault,self.root/'runtime',self.root/'missing.json');q.claim(self.id)
        raw=Path(receipt['raw_dir']);analysis=raw/'analysis.md';summary=self.vault/'source.md'
        analysis.write_text('Test analysis');summary.write_text('Test source')
        with self.assertRaises(ValueError):q.finish(self.id,[analysis,summary])
        self.assertEqual(q.jobs()[0]['state'],'processing')
        (raw/'document-review.md').write_text('附加说明.md: read full text; simulated document. No real decisions.')
        q.finish(self.id,[analysis,summary]);self.assertEqual(q.jobs()[0]['state'],'done')


class OpenAIDocumentHandoff(unittest.TestCase):
    setUp=openai_fixture.OpenAIPipelineTests.setUp
    tearDown=openai_fixture.OpenAIPipelineTests.tearDown
    caller=openai_fixture.OpenAIPipelineTests.caller
    ready=openai_fixture.OpenAIPipelineTests.ready
    def test_link_reaches_openai_archive_without_duplicate_job(self):
        row=attach_link(self.dir);self.ready();receipt=openai_fixture.a.submit(self.dir,self.vault)
        self.assertEqual(openai_fixture.a.submit(self.dir,self.vault),receipt)
        q=openai_fixture.p.bridge(self.vault);q.claim(receipt['file_id']);self.assertEqual(len(q.jobs()),1)
        check_package(self,receipt,row,self.vault)
    def test_openai_documents_claim_and_retry_preserve_originals(self):
        row=attach(self.dir);self.ready();receipt=openai_fixture.a.submit(self.dir,self.vault)
        self.assertEqual(openai_fixture.a.submit(self.dir,self.vault),receipt)
        q=openai_fixture.p.bridge(self.vault);q.claim(receipt['file_id']);self.assertEqual(len(q.jobs()),1)
        check_package(self,receipt,row,self.vault)


class PlaudDocumentHandoff(unittest.TestCase):
    setUp=plaud_fixture.PlaudIntegrationTests.setUp
    tearDown=plaud_fixture.PlaudIntegrationTests.tearDown
    load=plaud_fixture.PlaudIntegrationTests.load
    context=plaud_fixture.PlaudIntegrationTests.context
    def test_link_survives_plaud_context_claim_and_retry(self):
        folder=self.load();self.context(folder);row=attach_link(folder)
        receipt=plaud_fixture.p.submit(folder,self.vault,self.client);q=plaud_fixture.p.bridge(self.vault);q.claim(receipt['file_id'])
        self.assertEqual(plaud_fixture.p.submit(folder,self.vault,self.client),receipt)
        self.assertEqual(b.read(folder/'meeting.json')['documents'],[row])
        check_package(self,receipt,row,self.vault)
    def test_plaud_documents_survive_claim_and_reimport(self):
        folder=self.load();self.context(folder);row=attach(folder)
        receipt=plaud_fixture.p.submit(folder,self.vault,self.client);q=plaud_fixture.p.bridge(self.vault);q.claim(receipt['file_id'])
        self.assertEqual(plaud_fixture.p.submit(folder,self.vault,self.client),receipt)
        m=b.read(folder/'meeting.json'); self.assertEqual(m['documents'],[row])
        check_package(self,receipt,row,self.vault)

if __name__=='__main__':unittest.main()
